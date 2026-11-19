import AppKit
import Foundation
import SeatbayCore

/// What Claude's own updater has downloaded, read from Squirrel's request file.
///
/// Claude downloads updates into ~/Library/Caches/com.anthropic.claudefordesktop.ShipIt and writes
/// ShipItState.plist (JSON) pointing at the downloaded Claude.app. Its installer, ShipIt, waits for
/// every Claude that runs from Claude.app itself. Instances run from their own copy and never look
/// for updates, so only the regular Claude downloads them, and instances get the new version the
/// next time they open.
struct ClaudeUpdateStatus: Equatable {
    var installedVersion: String
    var stagedVersion: String?
    var stagedBundle: URL?
    var previousVersion: String?

    var pending: Bool {
        guard let stagedVersion else { return false }
        return stagedVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    static var shipItCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(SB.claudeBundleID).ShipIt", isDirectory: true)
    }
    static var requestURL: URL { shipItCache.appendingPathComponent("ShipItState.plist") }
    /// The copy kept for Roll Back. The folder name ends in ".noindex" so Spotlight and LaunchServices
    /// don't offer this older Claude as an app to open (it would open the main data folder).
    static var previousCopyURL: URL {
        let current = SB.supportDir.appendingPathComponent("PreviousClaude.noindex", isDirectory: true)
        let legacy = SB.supportDir.appendingPathComponent("PreviousClaude", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current.appendingPathComponent("Claude.app", isDirectory: true)
    }

    static func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]) as? String
    }

    /// Claude's installer replaces the app named in the request. Only a request for the installed
    /// Claude.app counts; one written by a Claude running from somewhere else is left alone.
    private static func targetsInstalledClaude(_ request: [String: Any]) -> Bool {
        guard let raw = request["targetBundleURL"] as? String, let target = URL(string: raw), target.isFileURL else { return true }
        guard let installed = AppBuilder.claudeAppURL else { return false }
        return SB.realPath(target.path) == SB.realPath(installed.path)
    }

    static func probe() -> ClaudeUpdateStatus {
        let installed = AppBuilder.claudeAppURL.flatMap(version(of:)) ?? "?"
        var status = ClaudeUpdateStatus(installedVersion: installed, stagedVersion: nil, stagedBundle: nil,
                                        previousVersion: version(of: previousCopyURL))
        if let data = try? Data(contentsOf: requestURL),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (request["bundleIdentifier"] as? String) == SB.claudeBundleID,
           let raw = request["updateBundleURL"] as? String, let url = URL(string: raw), url.isFileURL,
           FileManager.default.fileExists(atPath: url.path), targetsInstalledClaude(request) {
            status.stagedBundle = url
            status.stagedVersion = version(of: url)
        }
        return status
    }
}

struct UpdateHistoryEntry: Codable, Hashable {
    var date: Date
    var kind: String          // "update", "rollback", "restart", "guard"
    var detail: String
}

/// Runs "update all": quit every Claude, back each one up, run Claude's installer, reopen what was open.
@MainActor
final class UpdateCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case finished(String)
        case failed(String)

        var isWorking: Bool { if case .working = self { return true } else { return false } }
    }

    @Published private(set) var status = ClaudeUpdateStatus.probe()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [String] = []
    @Published private(set) var history: [UpdateHistoryEntry] = []

    private unowned let store: InstanceStore
    nonisolated static let anthropicTeamID = "Q6L2SF6YDW"
    private static var historyURL: URL { SB.supportDir.appendingPathComponent("update-history.json") }
    static var markerURL: URL { SB.supportDir.appendingPathComponent("update-in-progress") }

    init(store: InstanceStore) {
        self.store = store
        history = JSONFile.load(Self.historyURL, defaults: [UpdateHistoryEntry]())
    }

    func refresh() {
        let new = ClaudeUpdateStatus.probe()
        if new != status { status = new }
    }

    func dismissResult() {
        if !phase.isWorking { phase = .idle }
    }

    func record(_ kind: String, _ detail: String) {
        history.insert(UpdateHistoryEntry(date: Date(), kind: kind, detail: detail), at: 0)
        history = Array(history.prefix(50))
        try? JSONFile.save(history, to: Self.historyURL)
    }

    /// True while some Seatbay process (this one or the command line) is running an update.
    static var markerActive: Bool {
        guard let text = try? String(contentsOf: markerURL, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    private func step(_ text: String) {
        steps.append(text)
        phase = .working(text)
    }

    // MARK: Update all

    /// - Parameter requireUpdate: false = just restart every Claude (also applies an update if one is ready).
    /// - Parameter only: restart just these Claudes (ignored when an update is ready: installing needs every Claude closed).
    func updateAll(trigger: String, requireUpdate: Bool = true, only: [ClaudeTarget]? = nil) async {
        guard !phase.isWorking else { return }
        refresh()
        let before = status
        if requireUpdate, !before.pending {
            phase = .finished("Claude \(before.installedVersion) is up to date. Nothing to install.")
            return
        }
        // Claude's installer needs every Claude closed, so an update is only installed by a full round.
        // A round limited to some Claudes restarts just those and leaves a waiting update for later.
        if requireUpdate, only != nil {
            phase = .failed("An update closes every Claude, so it can't be limited to some of them. Run it without --only.")
            return
        }
        let install = before.pending && only == nil
        steps = []
        let settings = store.settings
        try? "\(getpid())".write(to: Self.markerURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: Self.markerURL) }

        // 1. Check the downloaded update before closing anything.
        if install, let staged = before.stagedBundle {
            step("Checking the signature of Claude \(before.stagedVersion ?? "")…")
            let verdict = await Task.detached { Self.verifyAnthropicSignature(staged) }.value
            if let problem = verdict {
                fail("The downloaded update didn't pass the signature check (\(problem)). Nothing was changed.")
                return
            }
        }

        // 2. Remember what is open.
        let subset = only
        let targets = subset ?? store.allTargets
        guard let exe = Snapshots.claudeExecutable else { fail(BuildError.claudeMissing.localizedDescription); return }
        let open = targets.filter { $0.runningPID(claudeExecutable: exe) != nil }
        step("Closing \(open.count) open Claude\(open.count == 1 ? "" : "s")…")

        // 3. Quit everything (expected exits: the safe-update guard leaves them alone).
        for target in open { store.quit(target, reason: .update) }
        let others = await waitForAllClaudesToQuit(timeout: 90, only: subset == nil ? nil : open)
        if !others.isEmpty {
            await reopen(open)
            fail("\(others.joined(separator: ", ")) didn't close (it may be asking about running sessions). Finish or stop its work and try again. Everything that was open has been reopened.")
            return
        }

        // 4. Back up each one that was closed, while it's closed.
        step("Backing up \(open.count) Claude\(open.count == 1 ? "" : "s")…")
        await store.backup(open, reason: "before update", force: true)

        // 5. Keep the current version for rollback, then run Claude's installer.
        var detail = "Restarted \(open.count) Claude\(open.count == 1 ? "" : "s")"
        if install, let stagedVersion = before.stagedVersion {
            if settings.keepPreviousVersion, let app = AppBuilder.claudeAppURL {
                step("Keeping a copy of Claude \(before.installedVersion) for rollback…")
                await Task.detached { Self.keepCopy(of: app) }.value
            }
            step("Installing Claude \(stagedVersion)…")
            let result = await Task.detached { Self.runShipIt() }.value
            refresh()
            if status.installedVersion != stagedVersion {
                await reopen(open)
                fail("Claude's installer didn't finish (\(result)). Claude \(status.installedVersion) is still installed and everything was reopened.")
                return
            }
            if let app = AppBuilder.claudeAppURL, let problem = await Task.detached(operation: { Self.verifyAnthropicSignature(app) }).value {
                await reopen(open)
                fail("Claude \(stagedVersion) was installed but its signature check failed (\(problem)). Use Roll Back if it doesn't open.")
                return
            }
            detail = "Updated Claude \(before.installedVersion) → \(stagedVersion); reopened \(open.count)"
        }

        // 6. Reopen exactly what was open, each with its own data folder.
        step("Reopening \(open.count) Claude\(open.count == 1 ? "" : "s")…")
        await reopen(open)
        if before.pending, !install { detail += "; the downloaded Claude \(before.stagedVersion ?? "update") waits for a full round" }
        record(install ? "update" : "restart", "\(detail) (\(trigger))")
        phase = .finished(detail + ".")
    }

    // MARK: Roll back

    func rollback() async {
        guard !phase.isWorking else { return }
        refresh()
        guard let previous = status.previousVersion, let app = AppBuilder.claudeAppURL else {
            phase = .failed("There is no earlier version kept to roll back to.")
            return
        }
        let current = status.installedVersion
        steps = []
        try? "\(getpid())".write(to: Self.markerURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: Self.markerURL) }

        step("Checking the kept copy of Claude \(previous)…")
        if let problem = await Task.detached(operation: { Self.verifyAnthropicSignature(ClaudeUpdateStatus.previousCopyURL) }).value {
            fail("The kept copy didn't pass the signature check (\(problem)). Nothing was changed.")
            return
        }
        guard let exe = Snapshots.claudeExecutable else { return }
        let open = store.allTargets.filter { $0.runningPID(claudeExecutable: exe) != nil }
        step("Closing \(open.count) open Claude\(open.count == 1 ? "" : "s")…")
        for target in open { store.quit(target, reason: .update) }
        let others = await waitForAllClaudesToQuit(timeout: 90)
        if !others.isEmpty {
            await reopen(open)
            fail("\(others.joined(separator: ", ")) didn't close. Nothing was changed.")
            return
        }
        step("Putting Claude \(previous) back…")
        let swapError = await Task.detached { () -> String? in
            let fm = FileManager.default
            let aside = app.deletingLastPathComponent().appendingPathComponent(".Claude-\(current)-\(UUID().uuidString.prefix(6)).app")
            do {
                try fm.moveItem(at: app, to: aside)
                do {
                    try fm.copyItem(at: ClaudeUpdateStatus.previousCopyURL, to: app)   // APFS clone: instant
                } catch {
                    try? fm.moveItem(at: aside, to: app)
                    return error.localizedDescription
                }
                try? fm.trashItem(at: aside, resultingItemURL: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        refresh()
        // Don't let automatic installs put the newer build straight back.
        store.updateSettings { $0.autoInstallPaused = true }
        step("Reopening \(open.count) Claude\(open.count == 1 ? "" : "s")…")
        await reopen(open)
        if let swapError {
            fail("Roll back failed: \(swapError). Claude \(current) is still installed.")
        } else {
            record("rollback", "Rolled back Claude \(current) → \(previous)")
            phase = .finished("Rolled back to Claude \(previous). Automatic installs are paused until you resume them.")
        }
    }

    // MARK: Helpers

    private func fail(_ message: String) {
        record("failed", message)
        phase = .failed(message)
    }

    private func reopen(_ targets: [ClaudeTarget]) async {
        guard let exe = Snapshots.claudeExecutable else { return }
        // The main Claude first. Each one has to be up before the next is asked for: macOS deals with
        // one app's open requests in turn (the next waits until the last app has finished starting),
        // and a command-line run must not end while a request is still waiting.
        for target in targets.sorted(by: { $0.isMain && !$1.isMain }) {
            store.launch(target)
            let deadline = Date().addingTimeInterval(30)
            while target.runningPID(claudeExecutable: exe) == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Waits until no Claude main process is left. Returns the names of any that are still open.
    private func waitForAllClaudesToQuit(timeout: TimeInterval, only: [ClaudeTarget]? = nil) async -> [String] {
        guard let exe = Snapshots.claudeExecutable else { return [] }
        let watched: () -> [ClaudeProcess] = {
            let all = ProcessInspector.claudeProcesses(executablePath: exe)
            guard let only else { return all }
            return all.filter { process in
                only.contains { $0.isMain ? process.dataDir == nil : process.dataDir == SB.normalize($0.dataDir.path) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if watched().isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // let helpers wind down
                return []
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return watched().map { process in
            store.allTargets.first { target in
                target.isMain ? process.dataDir == nil : process.dataDir == SB.normalize(target.dataDir.path)
            }?.name ?? "A Claude using \(process.dataDir ?? "the default data folder")"
        }
    }

    /// Clones the installed Claude.app (APFS copy-on-write, so it's instant and shares disk blocks).
    nonisolated static func keepCopy(of app: URL) {
        let fm = FileManager.default
        let destination = ClaudeUpdateStatus.previousCopyURL
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        try? fm.copyItem(at: app, to: destination)
    }

    /// Runs Squirrel's ShipIt (shipped inside Claude.app) on Claude's own update request.
    nonisolated static func runShipIt() -> String {
        guard let app = AppBuilder.claudeAppURL else { return "Claude.app not found" }
        let shipIt = app.appendingPathComponent("Contents/Frameworks/Squirrel.framework/Resources/ShipIt").path
        guard FileManager.default.isExecutableFile(atPath: shipIt) else { return "ShipIt is missing from Claude.app" }
        // Claude's installer normally takes seconds; if it hangs, give up so the round can reopen everything.
        let result = Shell.run(shipIt, ["\(SB.claudeBundleID).ShipIt", ClaudeUpdateStatus.requestURL.path], timeout: 600)
        if result.status == -2 { return "Claude's installer didn't finish within 10 minutes" }
        let lines = (result.stdout + "\n" + result.stderr).split(separator: "\n")
            .filter { !$0.contains("Unrecognized attribute") }
        return lines.last.map { String($0.split(separator: "]").last ?? $0).trimmingCharacters(in: .whitespaces) }
            ?? "ShipIt exited with \(result.status)"
    }

    /// nil when `app` is validly signed by Anthropic (team Q6L2SF6YDW) for Claude's bundle id.
    nonisolated static func verifyAnthropicSignature(_ app: URL) -> String? {
        let requirement = "identifier \"\(SB.claudeBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(anthropicTeamID)\""
        let result = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path])
        return result.status == 0 ? nil : (result.stderr.split(separator: "\n").last.map(String.init) ?? "codesign failed")
    }
}
