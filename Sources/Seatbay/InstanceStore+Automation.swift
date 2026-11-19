import AppKit
import Foundation
import SeatbayCore
import UserNotifications

enum QuitReason: String {
    case user, sleep, update, backup, restore
}

/// Per-Claude activity, used to decide when it is idle.
struct ActivityTracking {
    var lastFrontmost = Date.distantPast
    var lastBusy = Date()
    var lastCPU: (seconds: Double, at: Date)?
    var unexpectedExitAt: Date?
}

struct TargetHealth: Equatable {
    var pid: pid_t?
    var memory: UInt64 = 0
    var cpuPercent: Double = 0
    var processCount = 0
    var working = false
    var signedIn: Bool?
    var outdated = false          // started before the installed Claude was updated
    var sharesClaudeApp = false   // an instance still running straight from Claude.app (needs one restart)
    var idleMinutes: Int?
    var dataBytes: UInt64?
    var cacheBytes: UInt64?
}

struct Notice: Identifiable, Equatable {
    enum Kind { case info, warning }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

extension InstanceStore {
    /// CPU (percent of one core, averaged over the last tick) above which a Claude counts as busy.
    static let busyCPUPercent = 8.0
    /// How long the user and every Claude must be idle before an automatic install.
    static let autoInstallIdleSeconds: TimeInterval = 10 * 60

    func post(_ text: String, kind: Notice.Kind = .info, notify: Bool = false) {
        notices.insert(Notice(kind: kind, text: text), at: 0)
        notices = Array(notices.prefix(6))
        if notify { Notifier.post(title: "Seatbay", body: text) }
    }

    func dismissNotice(_ notice: Notice) { notices.removeAll { $0.id == notice.id } }

    // MARK: Events

    func noteActivated(pid: pid_t) {
        guard let id = pidToTarget[pid] else { return }
        tracking[id, default: ActivityTracking()].lastFrontmost = Date()
    }

    func handleExit(pid: pid_t) {
        guard let id = pidToTarget.removeValue(forKey: pid), let target = target(withID: id) else { return }
        if target.instance != nil {
            // The launcher's helper normally retires the instance's copy of Claude within a second
            // or two. If it was killed, do it from here.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                cleanRuntimeFiles()
            }
        }
        let expected = expectedExits.removeValue(forKey: id)
        let reason = expected.flatMap { Date().timeIntervalSince($0.at) < 300 ? $0.reason : nil }
        if reason == .update || reason == .restore || reason == .backup || UpdateCoordinator.markerActive { return }
        if reason == .sleep, let instance = target.instance { sleeping.insert(instance.id) }

        // Claude's installer waits for every Claude that runs from Claude.app itself. Instances have
        // their own copy now and neither check for updates nor get in its way, so this guard only
        // matters while instances opened by an older Seatbay are still around.
        let installerWasBlocked = claudeAppPIDs.contains(pid) && claudeAppPIDs.count > 1
        claudeAppPIDs.remove(pid)
        let wasFront = Date().timeIntervalSince(tracking[id]?.lastFrontmost ?? .distantPast) < 10
        if reason == nil, installerWasBlocked { tracking[id, default: ActivityTracking()].unexpectedExitAt = Date() }

        // Did Claude's updater close it? (An update is waiting, or ShipIt just ran, and you weren't using it.)
        updates.refresh()
        let shipItRanJustNow = Self.modificationDate(ClaudeUpdateStatus.shipItCache.appendingPathComponent("ShipIt_stderr.log"))
            .map { Date().timeIntervalSince($0) < 120 } ?? false
        let updaterClosedIt = reason == nil && !wasFront && installerWasBlocked && (updates.status.pending || shipItRanJustNow)
        let reopen = settings.safeUpdates && updaterClosedIt && allowGuardRelaunch(id)

        Task {
            if settings.backupOnQuit { await backup([target], reason: reason == .sleep ? "sleep" : "on quit", force: false) }
            guard reopen else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard runningPID(of: target) == nil, !updates.phase.isWorking else { return }
            launch(target)
            let text = "Claude's updater closed \(target.name), so Seatbay reopened it. The update installs safely from the Updates tab\(settings.autoInstallWhenIdle ? ", or by itself when you're away" : "")."
            updates.record("guard", "Reopened \(target.name) after Claude's updater closed it")
            post(text)
        }
    }

    /// At most 3 automatic reopenings per Claude per hour, so a quit loop can't run forever.
    private func allowGuardRelaunch(_ id: String) -> Bool {
        let recent = (guardRelaunches[id] ?? []).filter { Date().timeIntervalSince($0) < 3600 }
        guard recent.count < 3 else {
            guardRelaunches[id] = recent
            if let name = target(withID: id)?.name {
                post("\(name) keeps closing for an update, so Seatbay stopped reopening it. Install the update from the Updates tab.",
                     kind: .warning, notify: true)
            }
            return false
        }
        guardRelaunches[id] = recent + [Date()]
        return true
    }

    // MARK: Periodic work (every 5 s)

    func tick() {
        reloadIfChangedOnDisk()
        let sample = ProcessTable.sample()
        let awake = SystemState.pidsKeepingAwake()
        let frontPID = claudePID(of: NSWorkspace.shared.frontmostApplication)
        let now = Date()
        let claudeModified = AppBuilder.claudeAppURL.flatMap { Self.modificationDate($0.appendingPathComponent("Contents/Info.plist")) }

        var newHealth: [String: TargetHealth] = [:]
        var anyBusy = false
        for target in allTargets {
            var item = health[target.id] ?? TargetHealth()
            var track = tracking[target.id] ?? ActivityTracking()
            item.pid = runningPID(of: target)
            if let pid = item.pid {
                let tree = sample.tree(of: pid)
                item.memory = tree.reduce(0) { $0 + $1.footprint }
                item.processCount = tree.count
                let cpu = tree.reduce(0) { $0 + $1.cpuSeconds }
                if let last = track.lastCPU, now.timeIntervalSince(last.at) > 0.5 {
                    item.cpuPercent = max(0, (cpu - last.seconds) / now.timeIntervalSince(last.at) * 100)
                }
                track.lastCPU = (cpu, now)
                item.working = tree.contains { awake.contains($0.pid) }
                if pid == frontPID { track.lastFrontmost = now }
                if item.working || item.cpuPercent > Self.busyCPUPercent { track.lastBusy = now }
                let started = sample.entries[pid]?.startTime ?? now
                if track.lastBusy < started { track.lastBusy = started }
                let quietSince = max(track.lastBusy, track.lastFrontmost, started)
                item.idleMinutes = Int(now.timeIntervalSince(quietSince) / 60)
                item.outdated = claudeModified.map { started < $0.addingTimeInterval(-5) } ?? false
                item.sharesClaudeApp = target.instance.map { sharingClaudeApp.contains($0.id) } ?? false
                if item.working || item.cpuPercent > Self.busyCPUPercent { anyBusy = true }
            } else {
                item.memory = 0
                item.cpuPercent = 0
                item.processCount = 0
                item.working = false
                item.idleMinutes = nil
                item.outdated = false
                item.sharesClaudeApp = false
                track.lastCPU = nil
            }
            newHealth[target.id] = item
            tracking[target.id] = track
        }
        if anyBusy { lastClaudeBusy = now }
        lastSample = sample

        if now.timeIntervalSince(lastSignInCheck) > 60 {
            lastSignInCheck = now
            checkSignIns(into: &newHealth)
        }
        if newHealth != health { health = newHealth }
        if now.timeIntervalSince(lastSizeCheck) > 600 { refreshDiskSizes() }
        if now.timeIntervalSince(lastNightlyCheck) > 60 { checkNightly(now: now) }

        updates.refresh()
        guard monitoring else { return }
        sleepIdleInstances(now: now)
        detectOutsideUpdate()
        autoInstallIfIdle(now: now)
    }

    // MARK: Sign-in

    private func checkSignIns(into health: inout [String: TargetHealth]) {
        for target in allTargets {
            // A Claude on an API key or a cloud provider has no account to be signed in to.
            let signedIn = target.usesAPI ? nil : Self.isSignedIn(dataDir: target.dataDir)
            let before = health[target.id]?.signedIn
            health[target.id, default: TargetHealth()].signedIn = signedIn
            if before == true, signedIn == false {
                post("\(target.name) was signed out. Open it and sign in again\(target.isMain ? "" : " (use Sign In… so the link reaches it)").",
                     kind: .warning, notify: true)
            }
        }
    }

    /// Signed in = Claude's config.json holds its (encrypted) OAuth token cache. Only key names are read.
    nonisolated static func isSignedIn(dataDir: URL) -> Bool? {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json.contains { key, value in key.hasPrefix("oauth:tokenCache") && !((value as? String)?.isEmpty ?? true) }
    }

    func refreshDiskSizes() {
        lastSizeCheck = Date()
        let targets = allTargets
        Task.detached(priority: .utility) {
            var sizes: [String: (UInt64, UInt64)] = [:]
            for target in targets {
                sizes[target.id] = (DiskUsage.allocatedSize(of: target.dataDir), DiskUsage.cacheSize(in: target.dataDir))
            }
            let measured = sizes
            await MainActor.run {
                for (id, size) in measured {
                    self.health[id, default: TargetHealth()].dataBytes = size.0
                    self.health[id, default: TargetHealth()].cacheBytes = size.1
                }
            }
        }
    }

    func clearCaches(_ target: ClaudeTarget) {
        guard runningPID(of: target) == nil else {
            errorMessage = "Quit \(target.name) first; Claude is using its caches."
            return
        }
        do {
            let freed = try DiskUsage.clearCaches(in: target.dataDir)
            post("Cleared \(ByteFormat.file(freed)) of caches from \(target.name).")
            refreshDiskSizes()
        } catch {
            errorMessage = "Could not clear caches: \(error.localizedDescription)"
        }
    }

    // MARK: Sleep

    private func sleepIdleInstances(now: Date) {
        guard settings.sleepEnabled, !updates.phase.isWorking else { return }
        let limit = TimeInterval(max(1, settings.sleepAfterMinutes) * 60)
        for instance in instances where instance.neverSleep != true {
            guard let pid = runningPIDs[instance.id], expectedExits[instance.id.uuidString] == nil,
                  let item = health[instance.id.uuidString], !item.working,
                  let track = tracking[instance.id.uuidString] else { continue }
            let started = lastSample?.entries[pid]?.startTime ?? now
            let quietSince = max(track.lastBusy, track.lastFrontmost, started)
            guard now.timeIntervalSince(quietSince) >= limit else { continue }
            quit(ClaudeTarget(instance), reason: .sleep)
            post("\(instance.name) was idle for \(settings.sleepAfterMinutes) minutes, so it's sleeping now. Open it to wake it.")
        }
    }

    // MARK: Safe updates

    /// Claude got updated without Seatbay (e.g. everything quit and ShipIt installed):
    /// reopen what the updater closed in the last half hour.
    private func detectOutsideUpdate() {
        let installed = updates.status.installedVersion
        defer { lastInstalledVersion = installed }
        guard installed != lastInstalledVersion, lastInstalledVersion != "?", !updates.phase.isWorking,
              !UpdateCoordinator.markerActive else { return }
        updates.record("update", "Claude updated itself \(lastInstalledVersion) → \(installed)")
        let closed = !settings.safeUpdates ? [] : allTargets.filter { target in
            runningPID(of: target) == nil &&
                (tracking[target.id]?.unexpectedExitAt.map { Date().timeIntervalSince($0) < 1800 } ?? false)
        }
        for target in closed {
            tracking[target.id]?.unexpectedExitAt = nil
            launch(target)
        }
        var text = "Claude updated itself to \(installed)."
        if !closed.isEmpty { text += " Seatbay reopened \(closed.map(\.name).joined(separator: ", "))." }
        if !runningPIDs.isEmpty {
            text += " Instances that are open keep the earlier version until you restart them; Health shows which."
        }
        if !closed.isEmpty || !runningPIDs.isEmpty { post(text) }
    }

    private func autoInstallIfIdle(now: Date) {
        guard settings.safeUpdates, settings.autoInstallWhenIdle, !settings.autoInstallPaused,
              updates.status.pending, !updates.phase.isWorking, !UpdateCoordinator.markerActive,
              SystemState.userIdleSeconds >= Self.autoInstallIdleSeconds,
              now.timeIntervalSince(lastClaudeBusy) >= Self.autoInstallIdleSeconds else { return }
        Task { await updates.updateAll(trigger: "automatic, while you were away") }
    }
}

/// macOS notifications (asks for permission the first time).
enum Notifier {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
