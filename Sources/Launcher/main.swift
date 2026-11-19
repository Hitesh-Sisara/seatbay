// seatbay-launcher — the executable inside every generated "Claude <Name>.app".
//
// LaunchServices starts this tiny program. It makes a private copy-on-write clone of the installed,
// Anthropic-signed Claude.app, gives the clone this instance's coloured icon, and `exec`s the
// clone's Claude binary with `--user-data-dir=<instance folder>`.
//
// Why a clone: macOS identifies a running app by the path of the bundle it runs from. If every
// instance ran /Applications/Claude.app directly, macOS would treat them all as "the Claude in
// /Applications": clicking the regular Claude icon would bring an instance forward instead of
// opening your main Claude. Running from its own path makes each instance its own app.
//
// The clone is an APFS clone (instant, no extra disk space), is never patched or re-signed (so its
// code signature and keychain access are Claude's own), is made fresh on every launch (so it is
// always the installed version) and is retired when the instance quits by a detached copy of this
// program running in `--reap` mode, which leaves a link to this app at the clone's path.
//
// If this instance is already running, the launcher brings its window forward instead.

import AppKit
import Darwin
import Foundation
import SeatbayCore

// MARK: - Small helpers

func showAlertAndExit(_ title: String, _ message: String) -> Never {
    CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, nil, nil, nil,
                                   title as CFString, message as CFString, nil, nil, nil, nil)
    exit(1)
}

func log(_ message: String) { RuntimeFiles.log(message) }

// MARK: - Clean-up helper (`launcher --reap <pid> <instance id> <instance app> <Claude's executable name>`)

enum Reaper {
    static func waitForExit(of pid: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else { while kill(pid, 0) == 0 { usleep(500_000) }; return }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return }   // already gone
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) == -1 && errno == EINTR {}
    }

    /// After the watched Claude exits: is Claude relaunching itself from the same clone (app.relaunch)?
    /// Returns the new main process to watch, if so.
    static func successor(in dir: String, executableName: String) -> pid_t? {
        for _ in 0..<60 {   // up to ~15 s for Electron's relauncher to start the new process
            let users = ProcessInspector.processes(under: dir)
            if let main = users.first(where: { ProcessInspector.isCloneExecutable($0.executable, executableName: executableName) }) {
                return main.pid
            }
            let relaunching = users.contains { ProcessInspector.arguments(of: $0.pid)?.contains("--type=relauncher") ?? false }
            if !relaunching { return nil }
            usleep(250_000)
        }
        return nil
    }

    static func run(pid: pid_t, instanceID: String, wrapper: String, executableName: String) -> Never {
        for sig in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] { signal(sig, SIG_IGN) }
        let dir = SB.runtimeDir(instanceID: instanceID).path
        RuntimeFiles.sweepRetired()   // e.g. the clone a crash left behind, which the launcher just moved aside

        var watched = pid
        while true {
            waitForExit(of: watched)
            guard let next = successor(in: dir, executableName: executableName) else { break }
            log("reap \(instanceID): Claude relaunched itself (pid \(next)); still watching")
            watched = next
        }

        // A launcher holding the lock is starting this instance again and replaces the clone itself.
        let lock = RuntimeFiles.takeLock(instanceID, blocking: false)
        guard lock >= 0 else { log("reap \(instanceID): a new launch is under way; nothing to do"); exit(0) }
        if RuntimeFiles.cloneInUse(instanceID: instanceID, executableName: executableName) {
            log("reap \(instanceID): the instance is running again; nothing to do")
            exit(0)
        }
        let retired = RuntimeFiles.retireClone(instanceID: instanceID, linkTo: wrapper)
        RuntimeFiles.unlock(lock)

        if let retired {
            let gone = RuntimeFiles.deleteWhenUnused(retired)
            log("reap \(instanceID): clone retired\(gone ? " and deleted" : ", but it could not be deleted")")
        }
        RuntimeFiles.sweepRetired()
        exit(0)
    }

    /// Starts the clean-up helper as a detached process (own session, so it outlives the app).
    static func spawn(watching pid: pid_t, instanceID: String, wrapper: String, executableName: String) {
        let me = wrapper + "/Contents/MacOS/launcher"
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let arguments = [me, "--reap", "\(pid)", instanceID, wrapper, executableName]
        let cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var child: pid_t = 0
        let status = posix_spawn(&child, me, &actions, &attributes, cArguments, environ)
        if status != 0 { log("could not start the clean-up helper: \(String(cString: strerror(status)))") }
        cArguments.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
}

if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--reap", let pid = pid_t(CommandLine.arguments[2]) {
    Reaper.run(pid: pid, instanceID: CommandLine.arguments[3], wrapper: CommandLine.arguments[4],
               executableName: CommandLine.arguments[5])
}

// MARK: - Launch

let info = Bundle.main.infoDictionary ?? [:]
// This app's real location. macOS may have been handed the link that the clean-up helper leaves at
// the clone's path (a Dock tile kept from the last run, windows reopened at login); that link is
// replaced below, so nothing may depend on the path we were started through.
let wrapperURL = URL(fileURLWithPath: SB.realPath(Bundle.main.bundlePath), isDirectory: true)
let instanceName = (info["CFBundleDisplayName"] as? String) ?? "Claude instance"

guard let rawDataDir = info[SB.infoKeyDataDir] as? String, !rawDataDir.isEmpty else {
    showAlertAndExit("\(instanceName) is damaged",
                     "This instance app has no data folder configured. Open Seatbay and rebuild it.")
}
let dataDir = SB.normalize(rawDataDir)
let instanceID = (info[SB.infoKeyInstanceID] as? String) ?? ""

// Locate Claude.app: configured path first, then wherever LaunchServices knows it by bundle id.
var claudeAppURL = URL(fileURLWithPath: (info[SB.infoKeyTargetApp] as? String) ?? SB.defaultClaudeAppPath)
if !FileManager.default.fileExists(atPath: claudeAppURL.path) {
    if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SB.claudeBundleID) {
        claudeAppURL = found
    } else {
        showAlertAndExit("Claude is not installed",
                         "\(instanceName) runs your installed Claude app, but Claude.app could not be found. Install Claude from claude.ai/download and try again.")
    }
}
guard let executableURL = Bundle(url: claudeAppURL)?.executableURL,
      FileManager.default.isExecutableFile(atPath: executableURL.path) else {
    showAlertAndExit("Claude could not be started", "No executable was found inside \(claudeAppURL.path).")
}

/// Already running? Bring it forward instead of launching a duplicate on the same data folder.
func activateIfRunning() {
    guard let running = ProcessInspector.claudeProcesses(executablePath: executableURL.path)
        .first(where: { $0.dataDir == dataDir }) else { return }
    // A "reopen" event shows a window even if the user closed them all (same as clicking the Dock icon).
    let reopen = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: running.pid),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try? reopen.sendEvent(options: [.noReply], timeout: 2)
    NSRunningApplication(processIdentifier: running.pid)?.activate(options: [.activateAllWindows])
    exit(0)
}

activateIfRunning()

// One launcher at a time per instance (a double-click can start two). While waiting, the other
// launcher may finish starting the instance, in which case just bring it forward.
var lock: Int32 = -1
if !instanceID.isEmpty {
    for _ in 0..<150 {
        lock = RuntimeFiles.takeLock(instanceID, blocking: false)
        if lock >= 0 { break }
        usleep(100_000)
        activateIfRunning()
    }
    activateIfRunning()
    // Something may still run from the clone left by the last run:
    //  - Claude restarting itself (app.relaunch): wait for it, then bring it forward;
    //  - a bare copy started without this instance's data folder (macOS reopening it after a crash,
    //    say), which would show the regular Claude's account under this icon: ask it to quit.
    let name = executableURL.lastPathComponent
    var asked: Set<pid_t> = []
    for _ in 0..<100 {
        let mains = ProcessInspector.processes(under: SB.runtimeDir(instanceID: instanceID).path)
            .filter { ProcessInspector.isCloneExecutable($0.executable, executableName: name) }
        if mains.isEmpty { break }
        for process in mains where !asked.contains(process.pid) {
            guard let args = ProcessInspector.arguments(of: process.pid) else { continue }
            if ProcessInspector.dataDir(fromArguments: args) == nil, !args.contains(where: { $0.hasPrefix("--type=") }) {
                asked.insert(process.pid)
                log("\(instanceName): closing a copy of Claude that was started without this instance's data folder (pid \(process.pid))")
                kill(process.pid, SIGTERM)
            }
        }
        usleep(100_000)
        activateIfRunning()
    }
}

do {
    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
} catch {
    showAlertAndExit("\(instanceName) could not start", "Could not create its data folder at \(dataDir): \(error.localizedDescription)")
}

/// Clones Claude.app for this instance. Returns the clone, or nil when cloning isn't possible
/// (not an APFS volume, another volume, or the old clone can't be replaced).
func makeClone() -> URL? {
    guard !instanceID.isEmpty else { return nil }
    let fm = FileManager.default
    let dir = SB.runtimeDir(instanceID: instanceID)
    do {
        try fm.createDirectory(at: SB.runtimeRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Clones only cost nothing on a copy-on-write volume shared with Claude.app.
        let source = try claudeAppURL.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .volumeIdentifierKey])
        let target = try SB.runtimeRoot.resourceValues(forKeys: [.volumeIdentifierKey])
        guard source.volumeSupportsFileCloning == true,
              let a = source.volumeIdentifier, let b = target.volumeIdentifier, a.isEqual(b) else {
            log("\(instanceName): Claude.app can't be cloned here (different or non-APFS volume); running it directly")
            return nil
        }
        // Whatever is there goes: a clone left by a crash is moved aside (the clean-up helper deletes
        // it once nothing runs from it), the link left after the last run is simply removed.
        if RuntimeFiles.cloneName(instanceID: instanceID) != nil {
            _ = RuntimeFiles.retireClone(instanceID: instanceID, linkTo: nil)
        }
        guard RuntimeFiles.removeTree(dir.path) else { return nil }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clone = dir.appendingPathComponent(wrapperURL.lastPathComponent)
        try fm.copyItem(at: claudeAppURL, to: clone)   // APFS clone: instant, shares disk blocks
        return clone
    } catch {
        log("\(instanceName): could not clone Claude.app: \(error.localizedDescription); running it directly")
        return nil
    }
}

let started = Date()
var launchURL = executableURL
if let clone = makeClone(), let cloneExecutable = Bundle(url: clone)?.executableURL,
   FileManager.default.isExecutableFile(atPath: cloneExecutable.path) {
    // The instance's icon, shown by the Dock and the app switcher while it runs. It's a Finder
    // custom icon on the clone's folder, which leaves the signed contents untouched.
    if let icon = NSImage(contentsOf: wrapperURL.appendingPathComponent("Contents/Resources/AppIcon.icns")) {
        if !NSWorkspace.shared.setIcon(icon, forFile: clone.path, options: []) {
            log("\(instanceName): could not set the clone's icon")
        }
    }
    launchURL = cloneExecutable
    // Only the installed Claude updates itself. An instance must never download an update for its
    // clone or "relaunch to update" (Squirrel honours this switch).
    setenv("DISABLE_UPDATE_CHECK", "1", 1)
    Reaper.spawn(watching: getpid(), instanceID: instanceID, wrapper: wrapperURL.path,
                 executableName: executableURL.lastPathComponent)
    log("\(instanceName): starting from clone (\(Int(Date().timeIntervalSince(started) * 1000)) ms to prepare)")
}

var arguments = [launchURL.path, SB.dataDirSwitch + dataDir]
arguments += (info[SB.infoKeyExtraArgs] as? [String]) ?? []
// Forward anything we were started with (except the legacy process-serial-number flag).
arguments += CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

func execClaude(_ path: String) {
    var argv = arguments
    argv[0] = path
    let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    execv(path, cArguments)   // the lock is released here (close-on-exec)
    cArguments.forEach { free($0) }
}

execClaude(launchURL.path)
if launchURL != executableURL {
    log("\(instanceName): the clone would not start (\(String(cString: strerror(errno)))); running Claude.app directly")
    unsetenv("DISABLE_UPDATE_CHECK")
    execClaude(executableURL.path)
}

// Only reached if exec failed.
let reason = String(cString: strerror(errno))
showAlertAndExit("\(instanceName) could not start", "Starting \(executableURL.path) failed: \(reason)")
