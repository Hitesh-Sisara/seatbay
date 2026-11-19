import Foundation
import SeatbayCore

/// Backs up every Claude once a night and uploads the backups to S3-compatible storage.
///
/// A launchd agent (~/Library/LaunchAgents/in.sisara.seatbay.backup.plist) runs
/// `Seatbay --scheduled-backup` when the backup window opens and every 30 minutes after that, and
/// once when you log in. Each run exits at once unless a round is due. A round is due when the last
/// complete one is older than the most recent window start: inside the window that is tonight's round;
/// after it, a catch-up (the Mac was asleep or off at night, or the round failed), retried every
/// 30 minutes until one succeeds. macOS runs a missed timer as soon as the Mac wakes up.
///
/// A round backs up each Claude that changed since its last backup. Open Claudes are copied from a clone
/// of their folder, so nothing is closed or interrupted. Then every backup that isn't in S3 yet is
/// uploaded, oldest first, which also retries uploads that failed earlier (for example when the Mac
/// shut down in the middle of one).
enum NightlyBackup {
    struct State: Codable, Equatable {
        /// End of the last round in which every Claude was backed up and (with S3 on) uploaded.
        var lastSuccess: Date?
        var lastAttempt: Date?
        var lastError: String?
        var failuresInARow = 0
        var lastSummary: String?
    }

    struct Outcome {
        var ok: Bool
        var summary: String
        var problems: [String]
    }

    enum Due: Equatable {
        case no(String)
        case tonight
        case catchUp
    }

    static let agentLabel = "in.sisara.seatbay.backup"
    static let retryInterval: TimeInterval = 30 * 60

    static var stateURL: URL { SB.supportDir.appendingPathComponent("nightly-backup.json") }
    static var logURL: URL { SB.supportDir.appendingPathComponent("Logs/backup.log") }
    static var lockURL: URL { SB.supportDir.appendingPathComponent(".backup-round.lock") }
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func loadState() -> State { JSONFile.load(stateURL, defaults: State()) }

    // MARK: When

    /// Start of the most recent backup window at or before `now`.
    static func windowStart(before now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let hour = min(max(hour, 0), 23)
        // On a day when the clock skips this hour, the next valid time is used.
        let today = calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(-1),
                                      matching: DateComponents(hour: hour, minute: 0, second: 0),
                                      matchingPolicy: .nextTime) ?? now
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    static func due(now: Date = Date(), settings: AppSettings, state: State) -> Due {
        guard settings.nightlyBackup else { return .no("nightly backups are off") }
        let start = windowStart(before: now, hour: settings.nightlyHour)
        if let done = state.lastSuccess, done >= start { return .no("already done at \(done.formatted(date: .omitted, time: .shortened))") }
        if let tried = state.lastAttempt, tried >= start, now.timeIntervalSince(tried) < retryInterval - 60 {
            return .no("next try after \(tried.addingTimeInterval(retryInterval).formatted(date: .omitted, time: .shortened))")
        }
        return now < start.addingTimeInterval(3600) ? .tonight : .catchUp
    }

    /// For display: when the next round should run.
    static func nextRun(now: Date = Date(), settings: AppSettings, state: State) -> Date? {
        guard settings.nightlyBackup else { return nil }
        switch due(now: now, settings: settings, state: state) {
        case .tonight, .catchUp: return now
        case .no:
            let start = windowStart(before: now, hour: settings.nightlyHour)
            if let done = state.lastSuccess, done >= start {
                return Calendar.current.date(byAdding: .day, value: 1, to: start)
            }
            return state.lastAttempt.map { $0.addingTimeInterval(retryInterval) }
        }
    }

    // MARK: The round

    /// Runs one round now. Returns nil when another round is already running (in another process).
    static func runRound(trigger: String) async -> Outcome? {
        guard let lock = acquireLock() else { return nil }
        defer { flock(lock, LOCK_UN); close(lock) }

        let settings = SettingsFile.load()
        let now = Date()
        let windowStart = windowStart(before: now, hour: settings.nightlyHour)
        var state = loadState()
        state.lastAttempt = now
        saveState(state)
        log("round started (\(trigger))")

        var problems: [String] = []
        var made: [String] = []
        var current = 0
        let targets = [ClaudeTarget.main] + InstanceFile.load().map(ClaudeTarget.init)
        for target in targets {
            // A Claude that was never opened has nothing to back up yet.
            guard FileManager.default.fileExists(atPath: target.dataDir.path) else { continue }
            let latest = Snapshots.latest(targetID: target.id)
            let open = Snapshots.claudeExecutable.map { target.runningPID(claudeExecutable: $0) != nil } ?? false
            if let latest, latest.createdAt >= windowStart {
                current += 1   // already backed up since the window opened (an earlier try, or it quit)
                continue
            }
            if let latest, !open, let changed = Snapshots.lastChange(in: target.dataDir), changed <= latest.createdAt {
                current += 1   // closed and unchanged since its last backup
                continue
            }
            do {
                let info = try Snapshots.create(target, reason: "nightly", whileOpen: true)
                Snapshots.prune(targetID: target.id, keep: settings.keepLocalSnapshots)
                made.append(target.name)
                log("backed up \(target.name): \(info.id) \(ByteFormat.file(UInt64(info.bytes)))\(open ? " (while open)" : "")")
            } catch {
                problems.append("\(target.name): \(error.localizedDescription)")
                log("backup of \(target.name) failed: \(error.localizedDescription)")
            }
        }

        var uploaded = 0
        var cloudNote = ""
        if settings.s3.enabled && settings.s3.isConfigured {
            let waiting = Snapshots.listAll().filter { $0.uploadedAt == nil && $0.prunedFromRemote != true }
                .sorted { $0.createdAt < $1.createdAt }
            // Too big for one upload: kept on this Mac, noted once, never retried every 30 minutes.
            let tooBig = waiting.filter { $0.bytes > S3Backup.maxUploadBytes }
            if !tooBig.isEmpty { cloudNote = "; \(tooBig.count) backup\(tooBig.count == 1 ? "" : "s") too big to upload stay on this Mac" }
            let pending = waiting.filter { $0.bytes <= S3Backup.maxUploadBytes }
            for info in pending {
                do {
                    try await S3Backup.upload(info)
                    uploaded += 1
                    log("uploaded \(info.targetName) \(info.id)")
                } catch {
                    problems.append("upload of \(info.targetName)'s backup: \(error.localizedDescription)")
                    log("upload of \(info.targetName) \(info.id) failed: \(error.localizedDescription)")
                    break   // the storage is unreachable or refusing; the next try picks up from here
                }
            }
        } else {
            cloudNote = "; S3 is off, so backups stay on this Mac"
        }

        var summary = "\(made.count) backed up, \(current) already current"
        if uploaded > 0 { summary += ", \(uploaded) uploaded" }
        summary += cloudNote
        state = loadState()
        state.lastAttempt = now
        state.lastSummary = summary
        if problems.isEmpty {
            state.lastSuccess = Date()
            state.lastError = nil
            state.failuresInARow = 0
        } else {
            state.lastError = problems.joined(separator: "; ")
            state.failuresInARow += 1
        }
        saveState(state)
        log("round \(problems.isEmpty ? "finished" : "incomplete"): \(summary)\(problems.isEmpty ? "" : " — " + problems.joined(separator: "; "))")
        return Outcome(ok: problems.isEmpty, summary: summary, problems: problems)
    }

    /// The round lock, for other work on the Snapshots folder (nil while a round runs).
    static func tryLock() -> Int32? { acquireLock() }
    static func unlock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }

    private static func acquireLock() -> Int32? {
        try? FileManager.default.createDirectory(at: SB.supportDir, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return fd
    }

    private static func saveState(_ state: State) { try? JSONFile.save(state, to: stateURL) }

    static func log(_ line: String) {
        let url = logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) [\(getpid())] \(line)\n"
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(500_000).write(to: url)   // keep the newest half
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    // MARK: The launchd agent

    static func agentPlist(executable: String, hour: Int) -> [String: Any] {
        let out = SB.supportDir.appendingPathComponent("Logs/scheduled-backup.out").path
        return [
            "Label": agentLabel,
            "ProgramArguments": [executable, "--scheduled-backup"],
            "StartCalendarInterval": ["Hour": min(max(hour, 0), 23), "Minute": 0],
            "StartInterval": Int(retryInterval),
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": out,
            "StandardErrorPath": out,
        ]
    }

    /// Installs (or refreshes) the agent so it runs this copy of Seatbay, or removes it when
    /// nightly backups are off. Reloads launchd only when something changed.
    /// The agent's label before the rename; removed whenever the agent is synced.
    static let legacyAgentLabel = "com.multiclaude.backup"

    private static func removeLegacyAgent() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(legacyAgentLabel).plist")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        _ = launchctl(["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Where the app runs from when macOS has moved it to a random read-only folder ("App Translocation":
    /// an app opened straight from Downloads). An agent pointing there would break, so none is installed.
    static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    @discardableResult
    static func syncAgent(settings: AppSettings, executable: String? = Bundle.main.executablePath) -> String {
        removeLegacyAgent()
        guard settings.nightlyBackup else {
            guard FileManager.default.fileExists(atPath: agentURL.path) || agentLoaded() else { return "off" }
            _ = launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
            try? FileManager.default.removeItem(at: agentURL)
            return "removed"
        }
        guard let executable else { return "no executable" }
        if isTranslocated(executable) {
            return "not installed: move Seatbay to your Applications folder and open it from there"
        }
        let wanted = agentPlist(executable: executable, hour: settings.nightlyHour)
        let current = (try? Data(contentsOf: agentURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let loaded = agentLoaded()
        if let current, current.isEqual(to: wanted), loaded { return "up to date" }
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: SB.supportDir.appendingPathComponent("Logs"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
        } catch {
            return "could not write \(agentURL.path): \(error.localizedDescription)"
        }
        if loaded { _ = launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"]) }
        let result = launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
        return result.status == 0 ? "installed" : "written, but launchctl said: \(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)"
    }

    static func agentLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(agentLabel)"]).status == 0
    }

    private static func launchctl(_ args: [String]) -> Shell.Result { Shell.run("/bin/launchctl", args) }
}
