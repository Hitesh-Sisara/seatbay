import AppKit
import CoreServices
import CryptoKit
import Foundation
import SeatbayCore

enum BuildError: LocalizedError {
    case launcherMissing, claudeMissing, iconFailed
    case nameTaken(String)

    var errorDescription: String? {
        switch self {
        case .launcherMissing: return "The launcher is missing from Seatbay.app. Rebuild Seatbay with scripts/build.sh."
        case .claudeMissing: return "Claude.app was not found. Install Claude Desktop from claude.ai/download first."
        case .iconFailed: return "Could not read Claude's icon."
        case .nameTaken(let path): return "Something else already exists at \(path). Pick a different name."
        }
    }
}

/// Generates the small per-instance app bundle:
///
///     ~/Applications/<Name>.app
///       Contents/Info.plist          own name + bundle id + icon; MCDataDir/MCTargetApp keys
///       Contents/MacOS/launcher      seatbay-launcher (starts a private clone of Claude with --user-data-dir)
///       Contents/Resources/AppIcon.icns
///
/// Claude.app itself is never touched. While an instance runs, its clone of Claude.app lives in
/// ~/Library/Application Support/Seatbay/Runtime.noindex/<instance id>/ (see the launcher).
enum AppBuilder {
    static var embeddedLauncherURL: URL? {
        Bundle.main.url(forResource: "seatbay-launcher", withExtension: nil)
    }

    static var claudeAppURL: URL? {
        let standard = URL(fileURLWithPath: SB.defaultClaudeAppPath)
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: SB.claudeBundleID)
    }

    static var embeddedLauncherHash: String? {
        guard let url = embeddedLauncherURL, let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `appURL` is an instance app made by Seatbay (optionally: for this instance id).
    static func isInstanceApp(_ appURL: URL, id: UUID? = nil) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL),
              let stored = (info[SB.infoKeyInstanceID] ?? info[SB.legacyInfoKeyInstanceID]) as? String else {
            return false
        }
        return id.map { $0.uuidString == stored } ?? true
    }

    /// Whether the app exists and was built with the launcher currently shipped inside Seatbay.
    static func isUpToDate(_ instance: Instance) -> Bool {
        let plistURL = instance.appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) else { return false }
        return (info["SBLauncherHash"] as? String) == embeddedLauncherHash
            && (info[SB.infoKeyDataDir] as? String) == instance.dataDir
            && FileManager.default.isExecutableFile(atPath: instance.appURL.appendingPathComponent("Contents/MacOS/launcher").path)
    }

    static func build(_ instance: Instance, baseIcon: CGImage) throws {
        guard let launcher = embeddedLauncherURL else { throw BuildError.launcherMissing }
        guard let claude = claudeAppURL else { throw BuildError.claudeMissing }
        let fm = FileManager.default
        let app = instance.appURL
        if fm.fileExists(atPath: app.path), !isInstanceApp(app, id: instance.id) {
            throw BuildError.nameTaken(app.path)
        }

        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let launcherDest = macOS.appendingPathComponent("launcher")
        if fm.fileExists(atPath: launcherDest.path) { try fm.removeItem(at: launcherDest) }
        try fm.copyItem(at: launcher, to: launcherDest)

        let icon = IconRenderer.render(base: baseIcon, color: instance.color, number: instance.number,
                                       style: instance.style, label: instance.label, api: instance.usesAPI)
        try IconRenderer.writeICNS(icon, to: resources.appendingPathComponent("AppIcon.icns"))

        var plist: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": instance.bundleIdentifier,
            "CFBundleName": instance.name,
            "CFBundleDisplayName": instance.name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "LSApplicationCategoryType": "public.app-category.productivity",
            "NSHighResolutionCapable": true,
            "NSAppleEventsUsageDescription": "Brings this Claude instance's window to the front when you open it again.",
            SB.infoKeyInstanceID: instance.id.uuidString,
            SB.infoKeyDataDir: instance.dataDir,
            SB.infoKeyTargetApp: claude.path,
            "SBLauncherHash": embeddedLauncherHash ?? "",
            "SBInstanceNumber": instance.number,
        ]
        // Claude sets a few environment variables through its own Info.plist; LaunchServices applies
        // them to whatever app it launches, which is now our bundle, so carry them over.
        if let claudeInfo = NSDictionary(contentsOf: claude.appendingPathComponent("Contents/Info.plist")),
           let env = claudeInfo["LSEnvironment"] {
            plist["LSEnvironment"] = env
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        // Bundles we generate locally are not downloads; make sure no quarantine flag rides along.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // Ad-hoc sign the bundle so its Info.plist and icon are sealed together with the launcher.
        run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])

        // Tell LaunchServices / Finder / Dock the bundle (and its icon) changed.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        LSRegisterURL(app as CFURL, true)
        NSWorkspace.shared.noteFileSystemChanged(app.path)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
