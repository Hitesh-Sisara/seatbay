import AppKit
import Foundation
import SeatbayCore

extension InstanceStore {
    func reloadSnapshots() {
        var all: [String: [SnapshotInfo]] = [:]
        for info in Snapshots.listAll() { all[info.targetID, default: []].append(info) }
        snapshots = all
    }

    func lastBackup(of target: ClaudeTarget) -> Date? { snapshots[target.id]?.first?.createdAt }

    // MARK: Nightly backup (the round itself runs in the launchd agent; see NightlyBackup)

    /// Nightly backups are off until you turn them on. A Mac that already runs the backup agent (set up
    /// by an earlier version, before the setting existed in its settings file) keeps it on.
    func adoptExistingBackupSchedule() {
        guard !settings.nightlyPromptAnswered else { return }
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let existing = [NightlyBackup.agentLabel, NightlyBackup.legacyAgentLabel].contains {
            FileManager.default.fileExists(atPath: agents.appendingPathComponent("\($0).plist").path)
        }
        if existing { updateSettings { $0.nightlyBackup = true; $0.nightlyPromptAnswered = true } }
    }

    /// Clears what an interrupted backup or restore can leave behind (they hold copies of sign-in data).
    func sweepLeftovers() {
        Task.detached(priority: .utility) { Snapshots.sweepLeftovers() }
    }

    /// Installs, refreshes or removes the launchd agent to match the settings.
    func syncBackupAgent() {
        let settings = self.settings
        Task.detached(priority: .utility) {
            let result = NightlyBackup.syncAgent(settings: settings)
            guard result.hasPrefix("could not") || result.hasPrefix("written") || result.hasPrefix("not installed")
                    || result == "no executable" else { return }
            await MainActor.run { self.post("Nightly backup isn't scheduled: \(result)", kind: .warning) }
        }
    }

    /// Picks up rounds the agent finished, and warns when backups keep failing or haven't run.
    func checkNightly(now: Date) {
        lastNightlyCheck = now
        let state = NightlyBackup.loadState()
        if state != nightly {
            nightly = state
            reloadSnapshots()
        }
        guard settings.nightlyBackup, now.timeIntervalSince(nightlyWarnedAt) > 6 * 3600 else { return }
        let stale = state.lastSuccess.map { now.timeIntervalSince($0) > 36 * 3600 } ?? false
        guard state.failuresInARow >= 3 || stale else { return }
        nightlyWarnedAt = now
        let when = state.lastSuccess.map { "since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "yet"
        post("The nightly backup hasn't completed \(when)\(state.lastError.map { ": \($0)" } ?? "."). It keeps retrying every 30 minutes.",
             kind: .warning, notify: true)
    }

    /// One backup round now: every Claude (open ones from a clone, nothing is closed), then uploads.
    func backUpEverythingNow() async {
        backupStatus = "Backing up every Claude…"
        let outcome = await Task.detached(priority: .userInitiated) { await NightlyBackup.runRound(trigger: "Back Up Everything Now") }.value
        backupStatus = nil
        reloadSnapshots()
        nightly = NightlyBackup.loadState()
        guard let outcome else {
            post("A backup round is already running; it finishes on its own.")
            return
        }
        if outcome.ok {
            post("Backed up everything: \(outcome.summary).")
        } else {
            post("Backup round incomplete: \(outcome.problems.joined(separator: "; "))", kind: .warning)
        }
    }

    /// Backs up Claudes that are closed. `force: false` skips any backed up within the configured interval.
    func backup(_ targets: [ClaudeTarget], reason: String, force: Bool) async {
        let interval = TimeInterval(max(0, settings.backupMinIntervalHours) * 3600)
        let keep = settings.keepLocalSnapshots
        let toBackUp = targets.filter { target in
            force || (lastBackup(of: target).map { Date().timeIntervalSince($0) >= interval } ?? true)
        }
        guard !toBackUp.isEmpty else { return }
        var made: [SnapshotInfo] = []
        for target in toBackUp {
            backupStatus = "Backing up \(target.name)…"
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SnapshotInfo, Error> in
                do {
                    let info = try Snapshots.create(target, reason: reason)
                    Snapshots.prune(targetID: target.id, keep: keep)
                    return .success(info)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let info): made.append(info)
            case .failure(let error):
                // A Claude reopened mid-backup is not worth an alert; the next quit backs it up.
                if case SnapshotError.running = error { continue }
                post("Backup of \(target.name) failed: \(error.localizedDescription)", kind: .warning)
            }
        }
        backupStatus = nil
        reloadSnapshots()
        if settings.s3.enabled { await upload(made) }
    }

    /// Uploads snapshots to S3 (encrypted). Failures are reported but never block local backups.
    func upload(_ infos: [SnapshotInfo]) async {
        for info in infos {
            backupStatus = "Uploading \(info.targetName)…"
            do {
                try await S3Backup.upload(info)
            } catch {
                post("Upload of \(info.targetName)'s backup to S3 failed: \(error.localizedDescription)", kind: .warning)
                break
            }
        }
        backupStatus = nil
        reloadSnapshots()
    }

    func uploadPending() async {
        let all: [SnapshotInfo] = snapshots.values.flatMap { $0 }
        let waiting: [SnapshotInfo] = all.filter { (info: SnapshotInfo) -> Bool in info.uploadedAt == nil && info.prunedFromRemote != true }
        let pending = waiting.sorted { (a: SnapshotInfo, b: SnapshotInfo) -> Bool in a.createdAt < b.createdAt }
        guard !pending.isEmpty else {
            post("Every local backup is already in S3.")
            return
        }
        await upload(pending)
    }

    /// Waits for a Claude to finish quitting. Returns false on timeout.
    func waitUntilClosed(_ target: ClaudeTarget, timeout: TimeInterval = 45) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard let exe = Snapshots.claudeExecutable else { return false }
        while Date() < deadline {
            if target.runningPID(claudeExecutable: exe) == nil {
                try? await Task.sleep(nanoseconds: 800_000_000)   // let it finish flushing to disk
                refreshStatus()
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Backs up now. A running Claude is closed for the few seconds the backup takes, then reopened.
    func backupNow(_ target: ClaudeTarget) async {
        let wasRunning = runningPID(of: target) != nil
        if wasRunning {
            quit(target, reason: .backup)
            guard await waitUntilClosed(target) else {
                post("\(target.name) didn't close, so it wasn't backed up. It may be asking about running work.", kind: .warning)
                return
            }
        }
        await backup([target], reason: "manual", force: true)
        if wasRunning { launch(target, activate: false) }
        if let latest = snapshots[target.id]?.first, Date().timeIntervalSince(latest.createdAt) < 60 {
            post("Backed up \(target.name) (\(ByteFormat.file(UInt64(latest.bytes)))).")
        }
    }

    func deleteSnapshot(_ info: SnapshotInfo) {
        Snapshots.delete(info)
        reloadSnapshots()
    }

    // MARK: Restore

    func restore(_ info: SnapshotInfo, into target: ClaudeTarget) async {
        await restore(archive: Snapshots.archiveURL(info), label: info.id, into: target.forRestore(of: info))
    }

    func restoreRemote(_ remote: S3Backup.Remote, into target: ClaudeTarget) async {
        backupStatus = "Downloading the backup…"
        do {
            let info = try await S3Backup.metadata(remote)
            let file = try await S3Backup.download(remote)
            defer { try? FileManager.default.removeItem(at: file) }
            backupStatus = nil
            await restore(archive: file, label: remote.snapshotID, into: target.forRestore(of: info))
        } catch {
            backupStatus = nil
            post("Download failed: \(error.localizedDescription)", kind: .warning)
        }
    }

    private func restore(archive: URL, label: String, into target: ClaudeTarget) async {
        let wasRunning = runningPID(of: target) != nil
        if wasRunning {
            quit(target, reason: .restore)
            guard await waitUntilClosed(target) else {
                post("\(target.name) didn't close, so nothing was restored.", kind: .warning)
                return
            }
        }
        backupStatus = "Restoring \(target.name)…"
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SnapshotInfo?, Error> in
            do { return .success(try Snapshots.restore(archive: archive, into: target)) } catch { return .failure(error) }
        }.value
        backupStatus = nil
        reloadSnapshots()
        switch result {
        case .success(let safety):
            let undo = safety.map { " The previous state was saved as backup \($0.id)." } ?? ""
            post("Restored \(target.name) from \(label).\(undo) If it opens signed out, sign in again: logins only carry over on the Mac that made the backup.")
            if wasRunning { launch(target, activate: true) }
        case .failure(let error):
            post(error.localizedDescription, kind: .warning)
            if wasRunning { launch(target, activate: false) }
        }
        lastSignInCheck = .distantPast
    }

    /// Creates a new instance from a backup (e.g. one made on another Mac, or of an instance you deleted).
    func restoreAsNewInstance(archive: URL, info: SnapshotInfo, name: String) async {
        guard let base = baseIcon else { return }
        reloadIfChangedOnDisk()
        let id = UUID()
        let number = max(1, instances.map(\.number).max() ?? 1) + 1
        let instance = Instance(id: id, name: name, number: number,
                                colorName: info.colorName.flatMap { Palette.names.contains($0) ? $0 : nil } ?? "Blue",
                                style: info.style.flatMap(IconStyle.init(rawValue:)) ?? .colorAndNumber,
                                label: info.label ?? "",
                                // A backup of a Claude on an API key restores as an API instance.
                                dataDir: SB.instancesDataRoot.appendingPathComponent(id.uuidString).path
                                    + (info.usesAPI == true ? APIConfigFile.folderSuffix : ""),
                                createdAt: Date())
        backupStatus = "Creating \(name)…"
        let target = ClaudeTarget(instance)
        let result = await Task.detached { () -> Error? in
            do {
                try Snapshots.restore(archive: archive, into: target)
                try AppBuilder.build(instance, baseIcon: base)
                return nil
            } catch {
                return error
            }
        }.value
        backupStatus = nil
        if let result {
            post("Could not create \(name): \(result.localizedDescription)", kind: .warning)
            return
        }
        instances.append(instance)
        icons[instance.id] = previewIcon(for: instance)
        persistInstances()
        post("Created \(name) from the backup. Open it; if it's signed out, use Sign In… next to it.")
    }

    func restoreRemoteAsNewInstance(_ remote: S3Backup.Remote, name: String) async {
        backupStatus = "Downloading the backup…"
        do {
            let info = try await S3Backup.metadata(remote)
            let file = try await S3Backup.download(remote)
            defer { try? FileManager.default.removeItem(at: file) }
            backupStatus = nil
            await restoreAsNewInstance(archive: file, info: info, name: name)
        } catch {
            backupStatus = nil
            post("Download failed: \(error.localizedDescription)", kind: .warning)
        }
    }
}
