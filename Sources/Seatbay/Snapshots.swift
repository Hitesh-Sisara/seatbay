import CryptoKit
import Foundation
import SeatbayCore

/// A backup of one Claude's data folder, without caches and re-downloadable runtimes.
struct SnapshotInfo: Codable, Identifiable, Hashable {
    var id: String               // file stem, e.g. 20261111-181502-before-update
    var targetID: String
    var targetName: String
    var number: Int
    var colorName: String?
    var style: String?
    var label: String?
    var createdAt: Date
    var reason: String
    var claudeVersion: String
    var bytes: Int64
    var sha256: String
    var machine: String
    var uploadedAt: Date?
    /// Taken from a clone of the folder while that Claude was open (nightly backups).
    var whileOpen: Bool?
    /// The Claude ran on an API key or a gateway (its data folder ends in "-3p").
    var usesAPI: Bool?
    /// S3 dropped it to keep the configured number there; never uploaded again.
    var prunedFromRemote: Bool?

    var archiveName: String { "\(id).tar.gz" }
}

enum SnapshotError: LocalizedError {
    case running(String), tarFailed(String), missing(String), restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .running(let name): return "\(name) is running. Quit it first; a backup is only consistent while Claude is closed."
        case .tarFailed(let detail): return "The backup could not be written: \(detail)"
        case .missing(let detail): return "Backup not found: \(detail)"
        case .restoreFailed(let detail): return "Restore failed: \(detail)"
        }
    }
}

enum Snapshots {
    /// Top-level folders left out of backups. Claude rebuilds caches and re-downloads runtimes/VMs.
    static let excludedTopLevel = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                   "GraphiteDawnCache", "GPUPersistentCache", "Shared Dictionary", "Crashpad",
                                   "sentry", "Logs", "blob_storage", "vm_bundles", "claude-code", "claude-code-vm"]
    static let excludedNested = ["*/CacheStorage", "*/ScriptCache"]
    /// Lock files a running Claude holds; a restored copy must not carry them.
    static let excludedWhileOpen = ["SingletonLock", "SingletonSocket", "SingletonCookie", "RunningChromeVersion", "lockfile"]
    /// Big folders that are moved back from the old data folder after a restore, so nothing re-downloads.
    static let carriedOverOnRestore = ["vm_bundles", "claude-code", "claude-code-vm"]

    static var root: URL { SB.supportDir.appendingPathComponent("Snapshots", isDirectory: true) }

    static func folder(for targetID: String) -> URL { root.appendingPathComponent(targetID, isDirectory: true) }

    static func archiveURL(_ info: SnapshotInfo) -> URL { folder(for: info.targetID).appendingPathComponent(info.archiveName) }

    static func sidecarURL(_ info: SnapshotInfo) -> URL { folder(for: info.targetID).appendingPathComponent("\(info.id).json") }

    /// This Mac's folder name in S3 (`<prefix>/<machine>/<target>/…`). It is made once and kept in the
    /// "machine-id" file, so two Macs with the same name never share (and prune) one folder, and
    /// renaming the Mac doesn't strand its backups. A Mac that already has backups keeps their name.
    static var machineName: String {
        let file = SB.supportDir.appendingPathComponent("machine-id")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty, saved.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return saved
        }
        let existing = listAllUnfiltered().map(\.machine).first { !$0.isEmpty }
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let slug = raw.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let made = existing ?? "\(slug.isEmpty ? "mac" : slug)-\(UUID().uuidString.prefix(6).lowercased())"
        try? FileManager.default.createDirectory(at: SB.supportDir, withIntermediateDirectories: true)
        try? Data(made.utf8).write(to: file, options: .atomic)
        return made
    }

    /// Sidecars without touching `machineName` (which reads them to adopt an existing name).
    private static func listAllUnfiltered() -> [SnapshotInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.flatMap { id -> [SnapshotInfo] in
            let dir = folder(for: id)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(SnapshotInfo.self, from: Data(contentsOf: $0)) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static var claudeVersion: String {
        guard let app = AppBuilder.claudeAppURL,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return "?" }
        return (info["CFBundleShortVersionString"] as? String) ?? "?"
    }

    // MARK: Listing

    static func list(targetID: String) -> [SnapshotInfo] {
        let dir = folder(for: targetID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SnapshotInfo.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: archiveURL($0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func listAll() -> [SnapshotInfo] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.flatMap { list(targetID: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    static func latest(targetID: String) -> SnapshotInfo? { list(targetID: targetID).first }

    static func saveSidecar(_ info: SnapshotInfo) throws {
        try JSONFile.save(info, to: sidecarURL(info), privateFile: true)
    }

    // MARK: Create

    /// Archives `target`'s data folder.
    ///
    /// A closed Claude is archived as it is (checked before and after). An open one only when `whileOpen`
    /// is true: its folder is first cloned (APFS clones: a fraction of a second, no extra disk space) and
    /// the clone is archived, so the Claude keeps running and nothing is interrupted. Such a copy is like
    /// the folder after a power cut, which Claude recovers from; a backup of a closed Claude is cleaner.
    static func create(_ target: ClaudeTarget, reason: String, whileOpen allowOpen: Bool = false) throws -> SnapshotInfo {
        guard let claudeExe = claudeExecutable else { throw BuildError.claudeMissing }
        let open = target.runningPID(claudeExecutable: claudeExe) != nil
        if open && !allowOpen { throw SnapshotError.running(target.name) }
        guard FileManager.default.fileExists(atPath: target.dataDir.path) else {
            throw SnapshotError.tarFailed("\(target.name) has no data folder yet")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let safeReason = reason.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        var info = SnapshotInfo(id: "\(formatter.string(from: now))-\(safeReason)", targetID: target.id, targetName: target.name,
                                number: target.number, colorName: target.colorName,
                                style: target.instance?.style.rawValue, label: target.instance?.label,
                                createdAt: now, reason: reason, claudeVersion: claudeVersion,
                                bytes: 0, sha256: "", machine: machineName, uploadedAt: nil)
        info.whileOpen = open ? true : nil
        info.usesAPI = target.usesAPI ? true : nil

        var source = target.dataDir
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        if open {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let clone = root.appendingPathComponent(".staging-\(target.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            staging = clone
            try cloneDataFolder(target.dataDir, to: clone)
            source = clone
        }

        let dir = folder(for: target.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = archiveURL(info)
        let temp = dir.appendingPathComponent(".\(info.id).partial")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])

        var args = ["-czf", temp.path, "-C", source.path]
        for name in excludedTopLevel + excludedWhileOpen { args += ["--exclude", "./\(name)"] }
        for pattern in excludedNested { args += ["--exclude", pattern] }
        args.append(".")
        let result = Shell.run("/usr/bin/tar", args)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw SnapshotError.tarFailed(result.stderr.isEmpty ? "tar exited with \(result.status)" : result.stderr)
        }
        // If the Claude was opened while we were reading, the copy may be inconsistent: discard it.
        if !open, target.runningPID(claudeExecutable: claudeExe) != nil {
            try? FileManager.default.removeItem(at: temp)
            throw SnapshotError.running(target.name)
        }

        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        info.bytes = Int64(data.count)
        info.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.moveItem(at: temp, to: final)
        try saveSidecar(info)
        return info
    }

    /// Clones the top-level items of a data folder into `dest`, leaving out caches and the lock files
    /// a running Claude holds (a copy carrying them would make the new Claude hand itself to the old one).
    static func cloneDataFolder(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let skip = Set(excludedTopLevel + excludedWhileOpen)
        for name in try fm.contentsOfDirectory(atPath: source.path) where !skip.contains(name) {
            let from = source.appendingPathComponent(name), to = dest.appendingPathComponent(name)
            if clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) != 0, fm.fileExists(atPath: from.path) {
                // Not on APFS, or something changed underneath: copy instead (an item that vanishes is skipped).
                try? fm.copyItem(at: from, to: to)
            }
        }
    }

    /// The newest modification time of anything in a data folder that a backup would contain.
    static func lastChange(in dataDir: URL) -> Date? {
        let fm = FileManager.default
        let skip = Set(excludedTopLevel + excludedWhileOpen)
        var newest: Date?
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let top = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: keys) else { return nil }
        for item in top where !skip.contains(item.lastPathComponent) {
            func note(_ url: URL) {
                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   newest.map({ date > $0 }) ?? true { newest = date }
            }
            note(item)
            guard let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker {
                if ["CacheStorage", "ScriptCache"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                note(url)
            }
        }
        return newest
    }

    /// Clears what an interrupted backup or restore left behind. Partial archives and clones go; a
    /// folder set aside during a restore that stopped half-way goes back if the data folder is missing,
    /// and to the Trash otherwise. Only things older than an hour, and never while a backup round runs.
    static func sweepLeftovers() {
        guard let lock = NightlyBackup.tryLock() else { return }
        defer { NightlyBackup.unlock(lock) }
        let fm = FileManager.default
        let hourAgo = Date().addingTimeInterval(-3600)
        func isOld(_ url: URL) -> Bool {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (date ?? .distantPast) < hourAgo
        }
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if item.lastPathComponent.hasPrefix(".staging-") {
                if isOld(item) { try? fm.removeItem(at: item) }
            } else if let files = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasSuffix(".partial") && isOld(file) { try? fm.removeItem(at: file) }
            }
        }
        // In ~/Library/Application Support only the main Claude's own leftovers are touched.
        let parents: [(URL, (String) -> Bool)] = [
            (SB.instancesDataRoot, { _ in true }),
            (SB.mainClaudeDataDir.deletingLastPathComponent(), { $0.hasPrefix(".Claude.") || $0.hasPrefix(".Claude-3p.") }),
        ]
        for (parent, ours) in parents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                guard name.hasPrefix("."), ours(name), isOld(item) else { continue }
                if name.contains(".restore-") {
                    try? fm.trashItem(at: item, resultingItemURL: nil)
                } else if let range = name.range(of: ".replaced-") {
                    let original = parent.appendingPathComponent(String(name[name.index(after: name.startIndex)..<range.lowerBound]))
                    if fm.fileExists(atPath: original.path) {
                        try? fm.trashItem(at: item, resultingItemURL: nil)
                    } else {
                        try? fm.moveItem(at: item, to: original)
                    }
                }
            }
        }
    }

    static func prune(targetID: String, keep: Int) {
        for old in list(targetID: targetID).dropFirst(max(1, keep)) { delete(old) }
    }

    static func delete(_ info: SnapshotInfo) {
        try? FileManager.default.removeItem(at: archiveURL(info))
        try? FileManager.default.removeItem(at: sidecarURL(info))
    }

    // MARK: Restore

    /// Replaces `target`'s data folder with the contents of `archive`.
    /// The current folder is backed up first and then moved to the Trash, so a restore can be undone.
    /// Returns the safety snapshot of the folder that was replaced (nil if there was nothing to keep).
    @discardableResult
    static func restore(archive: URL, into target: ClaudeTarget) throws -> SnapshotInfo? {
        guard let claudeExe = claudeExecutable else { throw BuildError.claudeMissing }
        if target.runningPID(claudeExecutable: claudeExe) != nil { throw SnapshotError.running(target.name) }
        guard FileManager.default.fileExists(atPath: archive.path) else { throw SnapshotError.missing(archive.lastPathComponent) }

        let fm = FileManager.default
        let dataDir = target.dataDir
        let parent = dataDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // 1. Extract next to the real folder first, so a bad archive changes nothing.
        let staging = parent.appendingPathComponent(".\(dataDir.lastPathComponent).restore-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let untar = Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        guard untar.status == 0 else {
            try? fm.removeItem(at: staging)
            throw SnapshotError.restoreFailed(untar.stderr.isEmpty ? "the archive could not be unpacked" : untar.stderr)
        }

        // An API instance's connection lives in its data folder. A backup made before it was switched to
        // the API has none, so keep the current one rather than restore a folder that can't connect.
        let currentLibrary = APIConfigFile.library(dataDir)
        if target.instance?.usesAPI == true, APIConfigFile.load(dataDir: staging) == nil,
           fm.fileExists(atPath: currentLibrary.path) {
            let into = APIConfigFile.library(staging)
            try? fm.removeItem(at: into)
            try? fm.copyItem(at: currentLibrary, to: into)
        }

        // 2. Safety copy of what is there now.
        var safety: SnapshotInfo?
        if fm.fileExists(atPath: dataDir.path) {
            do {
                safety = try create(target, reason: "before restore")
            } catch {
                try? fm.removeItem(at: staging)   // it holds a copy of sign-in data
                throw error
            }
        }

        // 3. Swap folders, then carry big re-downloadable folders over from the old one.
        let old = parent.appendingPathComponent(".\(dataDir.lastPathComponent).replaced-\(UUID().uuidString.prefix(8))", isDirectory: true)
        if fm.fileExists(atPath: dataDir.path) { try fm.moveItem(at: dataDir, to: old) }
        do {
            try fm.moveItem(at: staging, to: dataDir)
        } catch {
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: dataDir.path) { try? fm.moveItem(at: old, to: dataDir) }
            try? fm.removeItem(at: staging)
            throw SnapshotError.restoreFailed(error.localizedDescription)
        }
        if fm.fileExists(atPath: old.path) {
            for name in carriedOverOnRestore {
                let from = old.appendingPathComponent(name), to = dataDir.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
            }
            try? fm.trashItem(at: old, resultingItemURL: nil)
        }
        return safety
    }

    static var claudeExecutable: String? {
        AppBuilder.claudeAppURL.flatMap { Bundle(url: $0)?.executableURL?.path }
    }
}

/// Runs a command and captures its output.
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// - Parameter timeout: stops the command (SIGTERM, then SIGKILL) if it runs longer; status is then -2.
    static func run(_ tool: String, _ arguments: [String], input: Data? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, stdout: "", stderr: error.localizedDescription) }
        if let inPipe, let input {
            DispatchQueue.global().async {
                // The command may exit before reading everything (ssh failing, say); SIGPIPE is ignored
                // app-wide, so this write just fails instead of killing Seatbay.
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        // Read both pipes concurrently so a chatty command can't fill one and block.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timedOut = TimedOutFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        process.waitUntilExit()
        group.wait()
        if timedOut.isSet {
            return Result(status: -2, stdout: String(decoding: outData, as: UTF8.self), stderr: "timed out after \(Int(timeout ?? 0)) seconds")
        }
        return Result(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A thread-safe flag for `Shell.run`'s timeout.
final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
