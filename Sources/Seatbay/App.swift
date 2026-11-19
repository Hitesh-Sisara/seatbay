import AppKit
import SeatbayCore
import SwiftUI

@main
struct SeatbayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Writing to a pipe whose reader has gone (an ssh that failed early) must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        CommandLineTools.runIfRequested()   // build-time helpers; exits when used
    }

    var body: some Scene {
        Window("Seatbay", id: "main") {
            ContentView()
                .environmentObject(delegate.store)
                .environmentObject(delegate.relay)
                .environmentObject(delegate.store.updates)
                .frame(minWidth: 760, minHeight: 600)
        }
        .defaultSize(width: 880, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rebuild All Instance Apps") { delegate.store.repairApps(force: true) }
            }
            CommandGroup(replacing: .help) {
                Link("Seatbay Help", destination: URL(string: "https://seatbay.sisara.in/docs")!)
                Link("Release Notes", destination: URL(string: "https://github.com/Hitesh-Sisara/seatbay/releases")!)
                Link("Report an Issue…", destination: URL(string: "https://github.com/Hitesh-Sisara/seatbay/issues/new/choose")!)
                Divider()
                Link("Source Code on GitHub", destination: URL(string: "https://github.com/Hitesh-Sisara/seatbay")!)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: InstanceStore
    let relay: SignInRelay

    override init() {
        store = InstanceStore()
        relay = SignInRelay(store: store)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Handle claude:// links ourselves (only used while a sign-in relay is active).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        relay.repairSchemeOwnership()
        store.repairApps()
        store.adoptExistingBackupSchedule()
        store.syncBackupAgent()
        store.sweepLeftovers()
        // `open -a "Seatbay" --args --sign-in "Claude Work"` starts a sign-in relay (handy from Raycast/Shortcuts).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--sign-in"), i + 1 < args.count,
           let instance = store.instances.first(where: { $0.name.caseInsensitiveCompare(args[i + 1]) == .orderedSame }) {
            relay.start(for: instance)
        }
    }

    /// Keeps running with the window closed while background features need it (backups on quit,
    /// sleep, safe updates). Click the Dock icon to bring the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let s = store.settings
        return relay.waitingInstanceID == nil && !s.backupOnQuit && !s.sleepEnabled && !s.safeUpdates
    }

    func applicationWillTerminate(_ notification: Notification) {
        if relay.waitingInstanceID != nil { relay.cancel() }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        relay.handle(url: url)
    }
}

/// Command-line helpers (the app exits after running one):
///
///     Seatbay --create-instance <name> <colour> <number> [label]   create an instance app
///     Seatbay --list                                               list instances
///     Seatbay --render-app-icon <out.icns> <icon.svg>              used by scripts/build.sh
///     Seatbay --render-preview <out.png> <colour> <number> <style> [label]
///
/// Backups, updates and other Macs: see AutomationCLI.
enum CommandLineTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1].hasPrefix("--") else { return }
        switch args[1] {
        case "--list":
            for i in InstanceFile.load() {
                print("#\(i.number)\t\(i.name)\t\(i.colorName)\t\(i.appURL.path)\t\(i.dataDir)")
            }
            exit(0)
        case "--create-instance":
            createInstance(Array(args.dropFirst(2)))
        case "--bypass-default":
            // --bypass-default on|off|status [settings.json path, default ~/.claude/settings.json]
            let file = args.count > 3 ? URL(fileURLWithPath: args[3]) : ClaudeCodeSettings.url
            let action = args.count > 2 ? args[2] : "status"
            do {
                switch action {
                case "on": try ClaudeCodeSettings.setBypassByDefault(true, at: file)
                case "off": try ClaudeCodeSettings.setBypassByDefault(false, at: file)
                case "status": break
                default: fputs("usage: Seatbay --bypass-default on|off|status [path]\n", stderr); exit(2)
                }
                print("permissions.defaultMode = \(ClaudeCodeSettings.defaultMode(at: file) ?? "(not set)")")
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        case "--import-profiles", "--backup", "--list-backups", "--restore-snapshot", "--configure-s3", "--s3-test",
             "--s3-list", "--s3-upload", "--s3-download", "--health", "--update-status", "--update-all", "--restart-all",
             "--other-mac-status", "--copy-profiles", "--scheduled-backup", "--backup-round", "--backup-schedule",
             "--configure-api", "--api-status", "--api-test":
            AutomationCLI.run(args)
        case let option where option.hasPrefix("--render"):
            render(args)
        default:
            return   // e.g. -NSDocumentRevisionsDebugMode from Xcode; let the app start
        }
    }

    private static func createInstance(_ args: [String]) -> Never {
        guard args.count >= 3, let number = Int(args[2]) else {
            fputs("usage: Seatbay --create-instance <name> <colour> <number> [label]\ncolours: \(Palette.names.joined(separator: ", "))\n", stderr)
            exit(2)
        }
        guard let claude = AppBuilder.claudeAppURL, let base = IconRenderer.claudeIcon(appURL: claude) else {
            fputs("Claude.app not found\n", stderr)
            exit(1)
        }
        if let problem = Instance.nameProblem(args[0]) { fputs("\(problem)\n", stderr); exit(2) }
        var list = InstanceFile.load()
        if list.contains(where: { Instance.fileSafe($0.name).lowercased() == Instance.fileSafe(args[0]).lowercased() }) {
            fputs("an instance called \(args[0]) already exists\n", stderr); exit(2)
        }
        let id = UUID()
        let instance = Instance(id: id, name: args[0], number: number,
                                colorName: Palette.names.contains(args[1]) ? args[1] : "Blue",
                                style: .colorAndNumber, label: args.count > 3 ? args[3] : "",
                                dataDir: SB.instancesDataRoot.appendingPathComponent(id.uuidString).path,
                                createdAt: Date())
        if list.contains(where: { Instance.fileSafe($0.name).lowercased() == Instance.fileSafe(instance.name).lowercased() }) {
            fputs("an instance named \(instance.name) already exists\n", stderr)
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(atPath: instance.dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try AppBuilder.build(instance, baseIcon: base)
            list.append(instance)
            try InstanceFile.save(list)
            print(instance.appURL.path)
            exit(0)
        } catch {
            fputs("create failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func renderView(_ which: String, to url: URL) throws {
        _ = NSApplication.shared
        let store = InstanceStore(monitoring: false)
        store.tick()
        let view: AnyView
        switch which {
        case "editor", "editor-api":
            var draft = store.makeDraft()
            if which == "editor-api" { draft.dataDir = draft.apiDataDir }
            view = AnyView(EditorView(target: .create(draft)).environmentObject(store))
        case "edit-first":
            guard let first = store.instances.first else { throw CocoaError(.fileNoSuchFile) }
            view = AnyView(EditorView(target: .edit(first)).environmentObject(store))
        case "main":
            view = AnyView(ContentView().environmentObject(store).environmentObject(SignInRelay(store: store))
                .environmentObject(store.updates).frame(width: 880, height: 860))
        case "nightly":
            view = AnyView(NightlyCard().environmentObject(store).environmentObject(store.updates).padding(16).frame(width: 860))
        case "backups":
            view = AnyView(BackupsTab().environmentObject(store).environmentObject(store.updates).frame(width: 860, height: 1500))
        default:
            throw CocoaError(.featureUnsupported)
        }
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        func scrollToTop(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let top = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            view.subviews.forEach(scrollToTop)
        }
        scrollToTop(host)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    private static func render(_ args: [String]) -> Never {
        guard args.count >= 3 else { fputs("missing output path\n", stderr); exit(2) }
        if args[1] == "--render-app-icon" {
            // --render-app-icon <out.icns> <icon.svg>   (no Claude needed: used by scripts/build.sh and CI)
            guard args.count >= 4 else { fputs("usage: --render-app-icon <out.icns> <icon.svg>\n", stderr); exit(2) }
            do {
                try IconRenderer.writeICNS(IconRenderer.appIcon(svg: URL(fileURLWithPath: args[3])), to: URL(fileURLWithPath: args[2]))
                exit(0)
            } catch {
                fputs("render failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        guard let claude = AppBuilder.claudeAppURL, let base = IconRenderer.claudeIcon(appURL: claude) else {
            fputs("Claude.app not found; cannot render icons\n", stderr)
            exit(1)
        }
        do {
            switch args[1] {
            case "--render-preview" where args.count >= 6:
                let style = IconStyle(rawValue: args[5]) ?? .colorAndNumber
                // --render-preview <png> <colour> <number> <style> [label] [--api]
                let extra = Array(args.dropFirst(6))
                let image = IconRenderer.render(base: base, color: Palette.color(named: args[3]),
                                                number: Int(args[4]) ?? 2, style: style,
                                                label: extra.first { $0 != "--api" } ?? "", api: extra.contains("--api"))
                try IconRenderer.writePNG(image, to: URL(fileURLWithPath: args[2]))
            case "--render-view" where args.count >= 4:
                // Draws a window's content off-screen (for checking layouts without a screen).
                try MainActor.assumeIsolated { try renderView(args[2], to: URL(fileURLWithPath: args[3])) }
            default:
                fputs("unknown option \(args[1])\n", stderr)
                exit(2)
            }
            exit(0)
        } catch {
            fputs("render failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
