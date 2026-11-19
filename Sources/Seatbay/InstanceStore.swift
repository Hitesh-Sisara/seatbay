import AppKit
import Foundation
import SeatbayCore

/// Owns the list of instances (persisted as JSON), their running state and every action on them.
@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published private(set) var runningPIDs: [UUID: pid_t] = [:]
    @Published private(set) var mainClaudePID: pid_t?
    /// Instances still running straight from the installed Claude.app (opened before every instance
    /// got its own copy of it). Until they are restarted, macOS can't tell them from the regular Claude.
    @Published private(set) var sharingClaudeApp: Set<UUID> = []
    @Published var icons: [UUID: NSImage] = [:]
    @Published private(set) var busy: Set<UUID> = []
    /// `permissions.defaultMode == "bypassPermissions"` in ~/.claude/settings.json (shared by every Claude).
    @Published private(set) var bypassByDefault = ClaudeCodeSettings.bypassByDefault
    @Published var errorMessage: String?

    // Automation, health and backups (see InstanceStore+Automation.swift and InstanceStore+Backups.swift).
    @Published private(set) var settings = SettingsFile.load()
    @Published var health: [String: TargetHealth] = [:]
    @Published var sleeping: Set<UUID> = []
    @Published var snapshots: [String: [SnapshotInfo]] = [:]
    @Published var backupStatus: String?
    @Published var nightly = NightlyBackup.loadState()
    var lastNightlyCheck = Date.distantPast
    var nightlyWarnedAt = Date.distantPast
    @Published var notices: [Notice] = []
    private(set) lazy var updates = UpdateCoordinator(store: self)

    var expectedExits: [String: (reason: QuitReason, at: Date)] = [:]
    var pidToTarget: [pid_t: String] = [:]
    var tracking: [String: ActivityTracking] = [:]
    var lastSample: ProcessTable?
    var lastSignInCheck = Date.distantPast
    var lastSizeCheck = Date.distantPast
    var lastInstalledVersion = ClaudeUpdateStatus.probe().installedVersion
    var lastClaudeBusy = Date()
    var guardRelaunches: [String: [Date]] = [:]
    /// Some Claude with its own data folder runs straight from Claude.app (see `sharingClaudeApp`).
    private var claudeAppIsShared = false
    /// Instances can only get their own copy of Claude when Claude.app and the home folder are on the
    /// same APFS volume. Otherwise they run Claude.app directly by design, which needs no restart.
    private lazy var instancesGetOwnCopy: Bool = {
        guard let app = AppBuilder.claudeAppURL else { return true }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let a = try? app.resourceValues(forKeys: keys), let b = try? home.resourceValues(forKeys: keys),
              let volumeA = a.volumeIdentifier as? NSObject, let volumeB = b.volumeIdentifier as? NSObject else { return true }
        return volumeA.isEqual(volumeB) && (a.volumeSupportsFileCloning ?? false)
    }()
    /// Every Claude running from Claude.app itself: the ones Claude's installer waits for.
    var claudeAppPIDs: Set<pid_t> = []
    private var handledStrays: Set<pid_t> = []
    private var sharingNoticePosted = false
    var instancesFileDate: Date?

    /// false for one-shot command-line use: no timers, and no automatic sleep or installs.
    let monitoring: Bool
    private var timer: Timer?
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private lazy var cachedBaseIcon: CGImage? = AppBuilder.claudeAppURL.flatMap { IconRenderer.claudeIcon(appURL: $0) }

    var claudeInstalled: Bool { AppBuilder.claudeAppURL != nil }
    var baseIcon: CGImage? { cachedBaseIcon }
    var mainClaudeIcon: NSImage {
        AppBuilder.claudeAppURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }

    /// - Parameter monitoring: false for one-shot command-line use (no timers or exit handling).
    init(monitoring: Bool = true) {
        self.monitoring = monitoring
        load()
        reloadSnapshots()
        refreshStatus()
        guard monitoring else { return }
        cleanRuntimeFiles()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }   // finds the Claude that went away and handles its exit
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let pid = self.claudePID(of: app) else { return }
                self.noteActivated(pid: pid)
            }
        })
        // The settings file can be edited elsewhere (an editor, the CLI's /config); re-read it on focus.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.bypassByDefault = ClaudeCodeSettings.bypassByDefault }
            })
    }

    func setBypassByDefault(_ enabled: Bool) {
        do {
            try ClaudeCodeSettings.setBypassByDefault(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        bypassByDefault = ClaudeCodeSettings.bypassByDefault
    }

    // MARK: Persistence

    private func load() {
        instances = InstanceFile.load()
        if let problem = InstanceFile.unreadable { errorMessage = problem.localizedDescription }
        instancesFileDate = Self.modificationDate(InstanceFile.url)
        for instance in instances { refreshIcon(instance) }
    }

    /// Picks up instances created or changed by the command line (e.g. "Copy profiles" from another Mac).
    func reloadIfChangedOnDisk() {
        let date = Self.modificationDate(InstanceFile.url)
        guard date != instancesFileDate else { return }
        load()
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        let scheduleChanged = copy.nightlyBackup != settings.nightlyBackup || copy.nightlyHour != settings.nightlyHour
        settings = copy
        do { try SettingsFile.save(copy) } catch { errorMessage = "Could not save settings: \(error.localizedDescription)" }
        if scheduleChanged { syncBackupAgent() }
    }

    func persistInstances() { save() }

    private func save() {
        defer { instancesFileDate = Self.modificationDate(InstanceFile.url) }
        do {
            try InstanceFile.save(instances)
        } catch {
            errorMessage = "Could not save instances: \(error.localizedDescription)"
        }
    }

    // MARK: Status

    /// Reads which Claudes are running from the process table, not from NSWorkspace. An instance
    /// takes over the process of its small launcher app, and macOS 27.0 then lists the app without a
    /// process id (`NSRunningApplication.processIdentifier` is -1), so NSWorkspace can't say which
    /// process an instance is. The process table always can.
    func refreshStatus() {
        let processes = Snapshots.claudeExecutable.map { ProcessInspector.claudeProcesses(executablePath: $0) } ?? []
        let byDir = Dictionary(instances.map { (SB.normalize($0.dataDir), $0.id) }, uniquingKeysWith: { a, _ in a })
        var running: [UUID: pid_t] = [:]
        var main: pid_t?
        var strays: [(pid: pid_t, executable: String)] = []
        for process in processes {
            // Should one Claude ever show up twice (a second copy that is about to give way to the
            // first), keep the process already known.
            if let dir = process.dataDir {
                guard let id = byDir[dir] else { continue }
                if running[id] == nil || process.pid == runningPIDs[id] { running[id] = process.pid }
            } else if process.runsFromClone {
                strays.append((process.pid, process.executable))   // an instance's copy of Claude, started without its data folder
            } else if main == nil || process.pid == mainClaudePID {
                main = process.pid
            }
        }
        let fromClaudeApp = processes.filter { !$0.runsFromClone }
        let onClaudeApp = Set(fromClaudeApp.map(\.pid))
        let sharing = instancesGetOwnCopy ? Set(running.filter { onClaudeApp.contains($0.value) }.keys) : []

        // A Claude that was running and no longer is has quit. (The state below still describes the
        // moment before, which is what `handleExit` wants.)
        let alive = Set(processes.map(\.pid))
        let stillOpen = Set(running.keys.map(\.uuidString) + (main == nil ? [] : [ClaudeTarget.mainID]))
        for (pid, id) in pidToTarget where !alive.contains(pid) {
            if monitoring, !stillOpen.contains(id) {
                handleExit(pid: pid)
            } else {
                pidToTarget.removeValue(forKey: pid)
            }
        }

        if running != runningPIDs { runningPIDs = running }
        if main != mainClaudePID { mainClaudePID = main }
        if sharing != sharingClaudeApp { sharingClaudeApp = sharing }
        claudeAppIsShared = fromClaudeApp.contains { $0.dataDir != nil }
        claudeAppPIDs = onClaudeApp
        // Remember who each pid was, so an exit can be attributed after the process is gone.
        for (id, pid) in running {
            pidToTarget[pid] = id.uuidString
            sleeping.remove(id)
        }
        if let main { pidToTarget[main] = ClaudeTarget.mainID }
        guard monitoring else { return }
        for stray in strays { closeStray(pid: stray.pid, executable: stray.executable) }
        noteSharedClaudeApp()
    }

    /// The process behind an app that NSWorkspace reports. Where macOS doesn't know it (see
    /// `refreshStatus`), the folder the app runs from tells which instance it is.
    func claudePID(of app: NSRunningApplication?) -> pid_t? {
        guard let app else { return nil }
        if app.processIdentifier > 0 { return app.processIdentifier }
        return app.bundleURL.flatMap { Self.instanceID(inRuntimePath: $0.path) }.flatMap { runningPIDs[$0] }
    }

    /// …/Runtime.noindex/<instance id>/<Name>.app/… → the instance id.
    static func instanceID(inRuntimePath path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard let root = parts.firstIndex(of: SB.runtimeRoot.lastPathComponent), root + 1 < parts.count else { return nil }
        return UUID(uuidString: parts[root + 1])
    }

    /// Asks a Claude to quit, the way the Dock's Quit does. Where macOS doesn't know which process
    /// the app is, the request goes to the process itself: Claude treats SIGTERM as Quit.
    func askToQuit(pid: pid_t) {
        guard pid > 1 else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.processIdentifier == pid, app.terminate() { return }
        kill(pid, SIGTERM)
    }

    /// Brings a running Claude's windows to the front.
    func bringForward(pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        if let app, app.processIdentifier == pid {
            app.activate(options: [.activateAllWindows])
            return
        }
        // macOS doesn't know this instance's process id (see `refreshStatus`). It does know the path
        // the instance runs from, and opening an app that is already running brings it forward.
        if app?.activate(options: [.activateAllWindows]) == true { return }
        guard let executable = ProcessInspector.executablePath(of: pid), ProcessInspector.isCloneExecutable(executable) else { return }
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: bundle, configuration: openConfiguration(activate: true)) { _, _ in }
    }

    /// An instance's copy of Claude was started bare (say from a Dock tile kept while it was running,
    /// clicked in the moment before the copy is retired). It would show the regular Claude's account
    /// under the instance's icon, so close it and open the instance the proper way.
    private func closeStray(pid: pid_t, executable: String) {
        guard handledStrays.insert(pid).inserted else { return }
        askToQuit(pid: pid)
        let owner = Self.instanceID(inRuntimePath: executable).flatMap { instance(withID: $0) }
        RuntimeFiles.log("closed a copy of Claude that was started without its data folder (pid \(pid), \(owner?.name ?? "unknown instance"))")
        guard let owner else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refreshStatus()
            open(owner)
        }
    }

    /// Tells you once when instances from before the "own copy of Claude" change are still open.
    private func noteSharedClaudeApp() {
        guard !sharingClaudeApp.isEmpty, !sharingNoticePosted else { return }
        sharingNoticePosted = true
        let names = instances.filter { sharingClaudeApp.contains($0.id) }.map(\.name).joined(separator: ", ")
        post("\(names) \(sharingClaudeApp.count == 1 ? "was" : "were") opened before this version of Seatbay. Until \(sharingClaudeApp.count == 1 ? "it is" : "they are") restarted once, clicking the regular Claude icon can still bring \(sharingClaudeApp.count == 1 ? "it" : "one of them") forward instead of your main Claude. Quit and reopen \(sharingClaudeApp.count == 1 ? "it" : "them") when it suits you, or use Health → Restart All Claudes.",
             kind: .warning)
    }

    /// Clears out what instances left in the runtime folder (see `RuntimeFiles.cleanUp`).
    func cleanRuntimeFiles() {
        let wrappers = Dictionary(instances.map { ($0.id.uuidString, $0.appURL.path) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .utility) { RuntimeFiles.cleanUp(wrappers: wrappers) }
    }

    var allTargets: [ClaudeTarget] { [ClaudeTarget.main] + instances.map(ClaudeTarget.init) }

    func target(withID id: String) -> ClaudeTarget? { allTargets.first { $0.id == id } }

    func runningPID(of target: ClaudeTarget) -> pid_t? {
        if target.isMain { return mainClaudePID }
        return target.instance.flatMap { runningPIDs[$0.id] }
    }

    func instance(withID id: UUID) -> Instance? { instances.first { $0.id == id } }
    func isRunning(_ instance: Instance) -> Bool { runningPIDs[instance.id] != nil }

    // MARK: Drafts

    func makeDraft() -> Instance {
        let number = max(1, instances.map(\.number).max() ?? 1) + 1
        let color = Palette.names.first { name in !instances.contains { $0.colorName == name } } ?? "Blue"
        let id = UUID()
        return Instance(id: id, name: "Claude \(number)", number: number, colorName: color, style: .colorAndNumber,
                        label: "", dataDir: SB.instancesDataRoot.appendingPathComponent(id.uuidString).path,
                        createdAt: Date())
    }

    func previewIcon(for instance: Instance) -> NSImage? {
        guard let base = baseIcon else { return nil }
        let image = IconRenderer.render(base: base, color: instance.color, number: instance.number,
                                        style: instance.style, label: instance.label, api: instance.usesAPI)
        return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }

    private func refreshIcon(_ instance: Instance) {
        if let icon = previewIcon(for: instance) { icons[instance.id] = icon }
    }

    /// Returns a user-facing problem with this name, or nil if it's fine.
    func nameProblem(_ name: String, excluding id: UUID?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Instance.nameProblem(trimmed) { return problem }
        let file = Instance.fileSafe(trimmed).lowercased()
        if instances.contains(where: { $0.id != id && Instance.fileSafe($0.name).lowercased() == file }) {
            return "Another instance already uses this name."
        }
        let target = SB.userApplicationsDir.appendingPathComponent("\(Instance.fileSafe(trimmed)).app")
        if FileManager.default.fileExists(atPath: target.path), !AppBuilder.isInstanceApp(target, id: id) {
            return "~/Applications already has an app with this name."
        }
        return nil
    }

    // MARK: Create / edit / delete

    /// - Parameter api: the API connection for an API instance; nil for a Claude account sign-in.
    func create(_ draft: Instance, copyMainData: Bool, api: APIConnection? = nil) async {
        reloadIfChangedOnDisk()
        guard let base = baseIcon else { errorMessage = BuildError.claudeMissing.localizedDescription; return }
        var instance = draft
        instance.name = instance.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if api != nil { instance.dataDir = instance.apiDataDir }
        busy.insert(instance.id)
        defer { busy.remove(instance.id) }
        do {
            let dataURL = URL(fileURLWithPath: instance.dataDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let api {
                try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try APIConfigFile.save(api, dataDir: dataURL, name: instance.name)
            } else if copyMainData, FileManager.default.fileExists(atPath: SB.mainClaudeDataDir.path) {
                // APFS clones the files, so this is quick and uses almost no extra disk space.
                let source = SB.mainClaudeDataDir
                try await Task.detached(priority: .userInitiated) {
                    try Snapshots.cloneDataFolder(source, to: dataURL)
                }.value
            } else {
                try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try AppBuilder.build(instance, baseIcon: base)
            instances.append(instance)
            refreshIcon(instance)
            save()
        } catch {
            errorMessage = "Could not create \(instance.name): \(error.localizedDescription)"
        }
    }

    /// - Parameter api: the connection it should use from now on: an API connection, or nil for a Claude
    ///   account. Switching between the two needs the instance closed; each mode keeps its own data
    ///   folder, so switching back finds the old sign-in (or API settings) and history again.
    func update(_ edited: Instance, api: APIConnection?) {
        reloadIfChangedOnDisk()
        guard let index = instances.firstIndex(where: { $0.id == edited.id }) else {
            errorMessage = "\(edited.name) no longer exists."
            return
        }
        guard let base = baseIcon else {
            errorMessage = "Nothing was saved: \(BuildError.claudeMissing.localizedDescription)"
            return
        }
        var instance = edited
        instance.name = instance.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = instances[index]
        let switching = old.usesAPI != (api != nil)
        if switching, isRunning(old) {
            errorMessage = "Quit \(old.name) first, then switch it to \(api == nil ? "a Claude account" : "an API key")."
            return
        }
        instance.dataDir = api == nil ? old.accountDataDir : old.apiDataDir
        var note: String?
        do {
            if let api {
                let dataURL = URL(fileURLWithPath: instance.dataDir, isDirectory: true)
                try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                if APIConfigFile.load(dataDir: dataURL) != api || old.name != instance.name {
                    try APIConfigFile.save(api, dataDir: dataURL, name: instance.name)
                    if !switching, isRunning(old) {
                        note = "Saved. Quit and reopen \(instance.name) to use the new API settings."
                    }
                }
            } else if switching {
                // Claude started on the account folder looks for API settings next to it; put them aside.
                try APIConfigFile.disable(dataDir: URL(fileURLWithPath: old.apiDataDir, isDirectory: true))
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: instance.dataDir, isDirectory: true),
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if old.appURL != instance.appURL, FileManager.default.fileExists(atPath: old.appURL.path) {
                if FileManager.default.fileExists(atPath: instance.appURL.path) {
                    throw BuildError.nameTaken(instance.appURL.path)
                }
                try FileManager.default.moveItem(at: old.appURL, to: instance.appURL)
            }
            try AppBuilder.build(instance, baseIcon: base)
            instances[index] = instance
            refreshIcon(instance)
            save()
            if old.appURL != instance.appURL { cleanRuntimeFiles() }
            let lookChanged = old.name != instance.name || old.number != instance.number || old.colorName != instance.colorName
                || old.style != instance.style || old.label != instance.label
            if let note {
                errorMessage = note
            } else if isRunning(instance), lookChanged {
                errorMessage = "Saved. Quit and reopen \(instance.name) to see the new icon in the Dock."
            }
        } catch {
            errorMessage = "Could not update \(instance.name): \(error.localizedDescription)"
        }
    }

    /// Quits the instance, waits until it has really closed (Claude may ask about running sessions,
    /// and the answer can be Cancel), and only then moves its app (and data) to the Trash.
    func delete(_ instance: Instance, deleteData: Bool) async {
        reloadIfChangedOnDisk()
        if isRunning(instance) {
            busy.insert(instance.id)
            quit(instance)
            let closed = await waitUntilClosed(ClaudeTarget(instance), timeout: 60)
            busy.remove(instance.id)
            guard closed else {
                errorMessage = "\(instance.name) is still open (it may be asking about running sessions), so nothing was deleted. Quit it, then delete it again."
                return
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: instance.appURL.path), AppBuilder.isInstanceApp(instance.appURL, id: instance.id) {
            try? fm.trashItem(at: instance.appURL, resultingItemURL: nil)
        }
        if deleteData {
            // An instance that was switched between a Claude account and an API key has both folders.
            for dir in [instance.accountDataDir, instance.apiDataDir] where fm.fileExists(atPath: dir) {
                try? fm.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
            }
        }
        instances.removeAll { $0.id == instance.id }
        icons[instance.id] = nil
        save()
        // Once it has quit, drop the copy of Claude it ran from (and the link its clean-up leaves).
        let id = instance.id.uuidString
        Task.detached(priority: .utility) {
            for _ in 0..<60 where RuntimeFiles.cloneInUse(instanceID: id) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // let its clean-up helper finish first
            RuntimeFiles.removeAll(instanceID: id)
        }
    }

    /// Rebuilds instance apps that are missing or were made by an older launcher.
    func repairApps(force: Bool = false) {
        guard let base = baseIcon else { return }
        for instance in instances where force || !AppBuilder.isUpToDate(instance) {
            do { try AppBuilder.build(instance, baseIcon: base) } catch {
                errorMessage = "Could not rebuild \(instance.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Running

    func open(_ instance: Instance, activate: Bool = true) {
        if let pid = runningPIDs[instance.id] {
            if activate { bringForward(pid: pid) }
            return
        }
        sleeping.remove(instance.id)
        if !FileManager.default.fileExists(atPath: instance.appURL.path), let base = baseIcon {
            try? AppBuilder.build(instance, baseIcon: base)
        }
        let config = openConfiguration(activate: activate)
        NSWorkspace.shared.openApplication(at: instance.appURL, configuration: config) { [weak self] _, error in
            guard let error else { return }
            RuntimeFiles.log("could not open \(instance.name): \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))")
            Task { @MainActor in self?.errorMessage = "Could not open \(instance.name): \(error.localizedDescription)" }
        }
    }

    func quit(_ instance: Instance) {
        quit(ClaudeTarget(instance), reason: .user)
    }

    /// Asks a Claude to quit and remembers why, so its exit isn't mistaken for the updater closing it.
    func quit(_ target: ClaudeTarget, reason: QuitReason) {
        refreshStatus()
        guard let pid = runningPID(of: target) else { return }
        expectedExits[target.id] = (reason, Date())
        askToQuit(pid: pid)
    }

    func launch(_ target: ClaudeTarget, activate: Bool = false) {
        refreshStatus()
        if target.isMain {
            openMainClaude(activate: activate)
        } else if let instance = target.instance.flatMap({ instance(withID: $0.id) }) {
            open(instance, activate: activate)
        }
    }

    /// Opens the regular Claude. Instances run from their own copy of Claude.app, so macOS doesn't
    /// confuse them with it. Only an instance opened by an older Seatbay still runs straight from
    /// Claude.app; while one is open LaunchServices would just bring it forward, so ask for a
    /// genuinely new process then.
    func openMainClaude(activate: Bool = true) {
        if let pid = mainClaudePID {
            if activate { bringForward(pid: pid) }
            return
        }
        guard let url = AppBuilder.claudeAppURL else { errorMessage = BuildError.claudeMissing.localizedDescription; return }
        let config = openConfiguration(activate: activate)
        config.createsNewApplicationInstance = claudeAppIsShared
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.errorMessage = "Could not open Claude: \(error.localizedDescription)" }
        }
    }

    /// A relocated home folder (CFFIXED_USER_HOME, used when testing) is passed on to what Seatbay opens.
    private func openConfiguration(activate: Bool) -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            config.environment = ["CFFIXED_USER_HOME": home]
        }
        return config
    }

    func revealApp(_ instance: Instance) {
        NSWorkspace.shared.activateFileViewerSelecting([instance.appURL])
    }

    func revealData(_ instance: Instance) {
        let url = URL(fileURLWithPath: instance.dataDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
