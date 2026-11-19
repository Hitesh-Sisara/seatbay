import Darwin
import Foundation

/// Constants shared by the manager app and the per-instance launcher.
public enum SB {
    /// Bundle identifier of the official Claude Desktop app.
    public static let claudeBundleID = "com.anthropic.claudefordesktop"
    public static let defaultClaudeAppPath = "/Applications/Claude.app"

    /// Chromium/Electron switch that moves all app data (cookies, login, settings) to another folder.
    public static let dataDirSwitch = "--user-data-dir="

    // Custom keys written into each generated instance app's Info.plist.
    public static let infoKeyTargetApp = "SBTargetApp"
    public static let infoKeyDataDir = "SBDataDir"
    public static let infoKeyInstanceID = "SBInstanceID"
    public static let infoKeyExtraArgs = "SBExtraArgs"

    public static let instanceBundleIDPrefix = "in.sisara.seatbay.instance."

    /// ~/Library/Application Support/Seatbay.
    /// Installs from before the rename (when the app was called "Multi Claude") keep using
    /// ~/Library/Application Support/MultiClaude: their instances' data folders, the copies of Claude
    /// they run from and their backups live there, and instance apps point at those paths.
    public static var supportDir: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = base.appendingPathComponent("Seatbay", isDirectory: true)
        let legacy = base.appendingPathComponent("MultiClaude", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.appendingPathComponent("instances.json").path) {
            return legacy
        }
        return current
    }

    /// Info.plist key that marked an instance app before the rename.
    public static let legacyInfoKeyInstanceID = "MCInstanceID"

    /// Where each instance's Claude data lives (one folder per instance).
    public static var instancesDataRoot: URL {
        supportDir.appendingPathComponent("Instances", isDirectory: true)
    }

    /// Main Claude's own data folder. Claude keeps a second one, "Claude-3p", when it is set up with
    /// an API key or a cloud provider instead of a Claude account; the one used last is the one that counts.
    public static var mainClaudeDataDir: URL {
        mainDataDirLock.lock()
        defer { mainDataDirLock.unlock() }
        if let cached = mainDataDirCache, Date().timeIntervalSince(cached.at) < 30 { return cached.url }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates = ["Claude", "Claude-3p"].map { base.appendingPathComponent($0, isDirectory: true) }
        func lastUsed(_ dir: URL) -> Date? {
            ["Cookies", "Network Persistent State", "config.json", "Preferences"].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.modificationDate] as? Date
            }.max()
        }
        let url = candidates.compactMap { dir in lastUsed(dir).map { (dir, $0) } }.max { $0.1 < $1.1 }?.0 ?? candidates[0]
        mainDataDirCache = (url, Date())
        return url
    }

    /// True when the main Claude runs on an API key or a cloud provider (no Claude account sign-in).
    public static var mainClaudeUsesAPIKey: Bool { mainClaudeDataDir.lastPathComponent.hasSuffix("-3p") }

    private static let mainDataDirLock = NSLock()
    nonisolated(unsafe) private static var mainDataDirCache: (url: URL, at: Date)?

    /// ~/Applications – generated instance apps go here so Spotlight, Raycast and Alfred find them.
    public static var userApplicationsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Where each running instance keeps its own copy-on-write clone of Claude.app:
    ///
    ///     Runtime.noindex/<instance id>/<Instance Name>.app
    ///
    /// Running from its own bundle path is what makes macOS treat an instance as a separate app
    /// (its own Dock icon, its own entry in the app switcher) instead of "the Claude in /Applications".
    /// `.noindex` keeps Spotlight from listing the clones as apps.
    public static var runtimeRoot: URL {
        supportDir.appendingPathComponent("Runtime.noindex", isDirectory: true)
    }

    public static func runtimeDir(instanceID: String) -> URL {
        runtimeRoot.appendingPathComponent(instanceID, isDirectory: true)
    }

    /// Lock file a launcher (or its clean-up helper) holds while it swaps an instance's clone.
    public static func runtimeLock(instanceID: String) -> URL {
        runtimeRoot.appendingPathComponent("\(instanceID).lock")
    }

    /// The path with every symlink resolved, the way the kernel reports executable paths
    /// (e.g. /tmp → /private/tmp). Works for paths that don't exist yet.
    public static func realPath(_ path: String) -> String {
        let clean = normalize(path)
        if let resolved = realpath(clean, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (clean as NSString).deletingLastPathComponent
        guard parent != clean, !parent.isEmpty else { return clean }
        return (realPath(parent) as NSString).appendingPathComponent((clean as NSString).lastPathComponent)
    }

    public static func normalize(_ path: String) -> String {
        var p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// A running Claude main process (not a helper/renderer).
public struct ClaudeProcess: Hashable {
    public let pid: pid_t
    /// `nil` means the process uses Claude's default data folder (the "main" Claude).
    public let dataDir: String?
    /// Path of the executable it runs.
    public let executable: String
    /// True when it runs from an instance's clone of Claude.app rather than the installed Claude.app.
    public let runsFromClone: Bool
}

/// Low-level process inspection that does not need AppKit (safe to call from the launcher before `exec`).
public enum ProcessInspector {
    /// Command line arguments of a process (argv), read with `sysctl(KERN_PROCARGS2)`.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }   // skip exec path
        while i < size && buffer[i] == 0 { i += 1 }   // skip padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// The `--user-data-dir` value of a Claude process, if any.
    public static func dataDir(fromArguments args: [String]) -> String? {
        for arg in args.dropFirst() where arg.hasPrefix(SB.dataDirSwitch) {
            return SB.normalize(String(arg.dropFirst(SB.dataDirSwitch.count)))
        }
        return nil
    }

    /// True when `path` is the main executable of a clone under the runtime root
    /// (helpers live in `Contents/Frameworks/…` and have other names).
    public static func isCloneExecutable(_ path: String, executableName: String = "Claude") -> Bool {
        path.hasPrefix(runtimeRootPrefix) && path.hasSuffix(".app/Contents/MacOS/" + executableName)
            && !path.contains(".app/Contents/Frameworks/")
    }

    private static let runtimeRootPrefix = SB.realPath(SB.runtimeRoot.path) + "/"

    /// Finds running main Claude processes: the installed Claude (`executablePath`) and every
    /// instance running from its own clone. Helper processes (renderer, GPU …) are ignored.
    public static func claudeProcesses(executablePath: String) -> [ClaudeProcess] {
        let target = SB.realPath(executablePath)
        let name = (target as NSString).lastPathComponent
        let me = getpid()
        return allPIDs().compactMap { pid in
            guard pid != me, let path = Self.executablePath(of: pid) else { return nil }
            let clone = isCloneExecutable(path, executableName: name)
            guard clone || path == target || SB.normalize(path) == SB.normalize(executablePath),
                  let args = arguments(of: pid), !args.contains(where: { $0.hasPrefix("--type=") }) else { return nil }
            return ClaudeProcess(pid: pid, dataDir: dataDir(fromArguments: args), executable: path, runsFromClone: clone)
        }
    }

    /// Every process (main or helper) whose executable lives under `directory`.
    public static func processes(under directory: String) -> [(pid: pid_t, executable: String)] {
        let prefix = SB.realPath(directory) + "/"
        let me = getpid()
        return allPIDs().compactMap { pid in
            guard pid != me, let path = executablePath(of: pid), path.hasPrefix(prefix) else { return nil }
            return (pid, path)
        }
    }
}

/// File handling for the per-instance clones under `SB.runtimeRoot`, shared by the launcher, its
/// clean-up helper and the manager app.
public enum RuntimeFiles {
    /// Where retired clones wait until their last helper process has gone.
    public static var retiredRoot: URL { SB.runtimeRoot.appendingPathComponent(".retired", isDirectory: true) }

    /// Short diagnostic log: ~/Library/Application Support/Seatbay/Logs/launcher.log
    public static func log(_ message: String) {
        let dir = SB.supportDir.appendingPathComponent("Logs", isDirectory: true)
        let file = dir.appendingPathComponent("launcher.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 512_000 {
            let old = dir.appendingPathComponent("launcher.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n"
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    public static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Deletes a file, a symlink (never what it points to) or a whole folder. True when nothing is left.
    @discardableResult
    public static func removeTree(_ path: String) -> Bool {
        guard exists(path) else { return true }
        if isSymlink(path) { return unlink(path) == 0 }
        do { try FileManager.default.removeItem(atPath: path) } catch {
            // Someone else (another clean-up helper) may have deleted it at the same moment.
            if exists(path) { log("could not delete \(path): \(error.localizedDescription)") }
        }
        return !exists(path)
    }

    /// Takes the per-instance lock that serialises "replace this instance's clone".
    /// Returns a descriptor (closed automatically on exec), or -1 if it is held elsewhere.
    public static func takeLock(_ instanceID: String, blocking: Bool) -> Int32 {
        try? FileManager.default.createDirectory(at: SB.runtimeRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(SB.runtimeLock(instanceID: instanceID).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        if flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return -1
    }

    public static func unlock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// The clone (a real folder, not the link left after a run) inside an instance's runtime folder.
    public static func cloneName(instanceID: String) -> String? {
        let dir = SB.runtimeDir(instanceID: instanceID).path
        return (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .first { $0.hasSuffix(".app") && !isSymlink(dir + "/" + $0) }
    }

    /// True when a main Claude process (not just a leftover helper) runs from this instance's clone.
    public static func cloneInUse(instanceID: String, executableName: String = "Claude") -> Bool {
        ProcessInspector.processes(under: SB.runtimeDir(instanceID: instanceID).path)
            .contains { ProcessInspector.isCloneExecutable($0.executable, executableName: executableName) }
    }

    /// Retires an instance's clone once its Claude has quit. Call with the instance's lock held.
    ///
    /// The clone is renamed out of the way at once, so nothing can start it bare (that would show the
    /// main Claude's account under the instance's icon). A link to the instance's own app
    /// (`linkTo`, the wrapper in ~/Applications) is left in its place: anything that remembered the
    /// clone's path (a Dock tile kept from the running app, "reopen windows" at login) then opens
    /// the instance the proper way, through its launcher.
    /// - Returns: where the retired clone now is (delete it with `deleteWhenUnused`), or nil.
    public static func retireClone(instanceID: String, linkTo wrapper: String?) -> String? {
        guard let name = cloneName(instanceID: instanceID) else { return nil }
        let dir = SB.runtimeDir(instanceID: instanceID).path
        try? FileManager.default.createDirectory(at: retiredRoot, withIntermediateDirectories: true)
        let retired = retiredRoot.appendingPathComponent("\(instanceID)-\(getpid())-\(Int(Date().timeIntervalSince1970))").path
        guard rename(dir, retired) == 0 else {
            log("\(instanceID): could not retire the clone: \(String(cString: strerror(errno)))")
            return nil
        }
        if let wrapper, mkdir(dir, 0o700) != 0 || symlink(wrapper, dir + "/" + name) != 0 {
            log("\(instanceID): could not leave a link to the instance app: \(String(cString: strerror(errno)))")
        }
        return retired
    }

    /// Removes everything kept for an instance that no longer exists: its clone, the link and the
    /// lock. Does nothing while the instance is running or being started.
    public static func removeAll(instanceID: String) {
        let lock = takeLock(instanceID, blocking: false)
        guard lock >= 0 else { return }
        if cloneInUse(instanceID: instanceID) { unlock(lock); return }
        let retired = retireClone(instanceID: instanceID, linkTo: nil)
        removeTree(SB.runtimeDir(instanceID: instanceID).path)   // holds at most the link (never followed)
        unlink(SB.runtimeLock(instanceID: instanceID).path)
        unlock(lock)
        if let retired { deleteWhenUnused(retired, maxWait: 30) }
    }

    /// Tidies the runtime folder (the manager runs this when it starts): retires clones whose Claude
    /// is gone (a crash, a forced quit or a power cut skipped the clean-up helper), points the links
    /// at where each instance app is now, forgets deleted instances and empties the retired folder.
    /// - Parameter wrappers: instance id → path of its app in ~/Applications.
    public static func cleanUp(wrappers: [String: String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: SB.runtimeRoot.path)) ?? []
        var ids = Set<String>()
        for name in names where !name.hasPrefix(".") {
            ids.insert(name.hasSuffix(".lock") ? String(name.dropLast(5)) : name)
        }
        for id in ids {
            guard let wrapper = wrappers[id] else { removeAll(instanceID: id); continue }
            let lock = takeLock(id, blocking: false)
            guard lock >= 0 else { continue }
            var retired: String?
            if cloneName(instanceID: id) != nil {
                if !cloneInUse(instanceID: id) { retired = retireClone(instanceID: id, linkTo: wrapper) }
            } else {
                // Only the link is there: re-point it if the instance app was renamed or moved.
                let dir = SB.runtimeDir(instanceID: id).path
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                    let link = dir + "/" + name
                    guard isSymlink(link), (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != wrapper else { continue }
                    unlink(link)
                    _ = symlink(wrapper, link)
                }
            }
            unlock(lock)
            if let retired {
                log("\(id): retired a clone left behind by an earlier run")
                deleteWhenUnused(retired, maxWait: 10)
            }
        }
        sweepRetired()
    }

    /// Waits for the last helper processes of a retired clone to finish, then deletes it.
    @discardableResult
    public static func deleteWhenUnused(_ retired: String, maxWait: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline, !ProcessInspector.processes(under: retired).isEmpty { usleep(500_000) }
        return removeTree(retired)
    }

    /// Deletes retired clones left behind by a crash or a logout (anything no process runs from).
    public static func sweepRetired() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: retiredRoot.path) else { return }
        for name in names {
            let path = retiredRoot.appendingPathComponent(name).path
            if ProcessInspector.processes(under: path).isEmpty { removeTree(path) }
        }
    }
}
