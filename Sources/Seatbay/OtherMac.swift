import CryptoKit
import Foundation
import SeatbayCore

/// The look of an instance, without its data or sign-in. What "Copy profiles" sends to another Mac.
struct InstanceProfile: Codable, Hashable {
    var name: String
    var number: Int
    var colorName: String
    var style: String
    var label: String
    var neverSleep: Bool?

    init(_ instance: Instance) {
        name = instance.name
        number = instance.number
        colorName = instance.colorName
        style = instance.style.rawValue
        label = instance.label
        neverSleep = instance.neverSleep
    }
}

enum Profiles {
    struct ImportResult {
        var created: [String] = []
        var updated: [String] = []
        var unchanged: [String] = []
        var failed: [String] = []

        var summary: String {
            var parts: [String] = []
            if !created.isEmpty { parts.append("created \(created.joined(separator: ", "))") }
            if !updated.isEmpty { parts.append("updated \(updated.joined(separator: ", "))") }
            if !unchanged.isEmpty { parts.append("\(unchanged.count) already up to date") }
            if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: "; "))") }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: "; ")
        }
    }

    /// Creates missing instances and updates the look of same-named ones. Never deletes anything,
    /// and never touches an existing instance's data folder.
    static func importProfiles(_ profiles: [InstanceProfile]) -> ImportResult {
        var result = ImportResult()
        guard let claude = AppBuilder.claudeAppURL, let base = IconRenderer.claudeIcon(appURL: claude) else {
            result.failed.append("Claude.app is not installed on this Mac")
            return result
        }
        var list = InstanceFile.load()
        for profile in profiles {
            let key = Instance.fileSafe(profile.name).lowercased()
            let style = IconStyle(rawValue: profile.style) ?? .colorAndNumber
            let color = Palette.names.contains(profile.colorName) ? profile.colorName : "Blue"
            if let index = list.firstIndex(where: { Instance.fileSafe($0.name).lowercased() == key }) {
                var instance = list[index]
                let before = instance
                instance.number = profile.number
                instance.colorName = color
                instance.style = style
                instance.label = profile.label
                instance.neverSleep = profile.neverSleep
                if instance == before, AppBuilder.isUpToDate(instance) {
                    result.unchanged.append(profile.name)
                    continue
                }
                do {
                    try AppBuilder.build(instance, baseIcon: base)
                    list[index] = instance
                    result.updated.append(profile.name)
                } catch {
                    result.failed.append("\(profile.name): \(error.localizedDescription)")
                }
            } else {
                let id = UUID()
                if let problem = Instance.nameProblem(profile.name) {
                    result.failed.append("\(profile.name): \(problem)")
                    continue
                }
                let instance = Instance(id: id, name: profile.name, number: profile.number, colorName: color, style: style,
                                        label: profile.label,
                                        dataDir: SB.instancesDataRoot.appendingPathComponent(id.uuidString).path,
                                        createdAt: Date(), neverSleep: profile.neverSleep)
                do {
                    try FileManager.default.createDirectory(atPath: instance.dataDir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try AppBuilder.build(instance, baseIcon: base)
                    list.append(instance)
                    result.created.append(profile.name)
                } catch {
                    result.failed.append("\(profile.name): \(error.localizedDescription)")
                }
            }
        }
        do { try InstanceFile.save(list) } catch { result.failed.append("saving the list: \(error.localizedDescription)") }
        return result
    }
}

/// Talks to another Mac over SSH (key-based, never prompts) to install Seatbay and copy profiles.
enum OtherMac {
    struct Status: Equatable {
        var macOS = ""
        var claudeVersion: String?
        var seatbayInstalled = false
        var seatbayCurrent = false
        var seatbayRunning = false
        var instanceNames: [String] = []
        var bypassDefault: String?
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let remoteApp = "$HOME/Applications/Seatbay.app"
    static let remoteBinary = remoteApp + "/Contents/MacOS/Seatbay"
    /// The app's name before the rename; replaced when Seatbay is installed there.
    static let legacyRemoteApp = "$HOME/Applications/Multi Claude.app"

    /// A problem with a host as typed, or nil. Anything that ssh could read as an option is refused.
    static func hostProblem(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter the other Mac as user@host." }
        if trimmed.hasPrefix("-") || trimmed.contains(where: { $0.isWhitespace || $0.isNewline || "'\"`;|&$<>\\".contains($0) }) {
            return "“\(host)” isn't a valid SSH host. Use user@host, for example me@studio.local."
        }
        return nil
    }

    static func ssh(_ host: String, _ command: String, input: Data? = nil) -> Shell.Result {
        if let problem = hostProblem(host) { return Shell.Result(status: 2, stdout: "", stderr: problem) }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
        // .local names often resolve to IPv6 first, which some Macs don't answer on.
        if host.hasSuffix(".local") { args.insert("-4", at: 0) }
        return Shell.run("/usr/bin/ssh", args + ["--", host.trimmingCharacters(in: .whitespaces), command], input: input)
    }

    static var localBuildHash: String {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func status(host: String) throws -> Status {
        let script = """
        echo "MACOS=$(sw_vers -productVersion)"
        echo "CLAUDE=$(defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)"
        B="\(remoteBinary)"
        L="\(legacyRemoteApp)/Contents/MacOS/MultiClaude"
        if [ ! -x "$B" ] && [ -x "$L" ]; then B="$L"; echo "SB_LEGACY=1"; fi
        if [ -x "$B" ]; then echo "SB_HASH=$(shasum -a 256 "$B" | cut -c1-64)"; "$B" --list 2>/dev/null | cut -f2 | sed 's/^/INSTANCE=/'; "$B" --bypass-default status 2>/dev/null | sed 's/^.*= /BYPASS=/'; fi
        pgrep -f "Contents/MacOS/(Seatbay|MultiClaude)$" >/dev/null && echo "SB_RUNNING=1"
        true
        """
        let result = ssh(host, script)
        guard result.status == 0 else {
            throw Failure(message: result.stderr.isEmpty ? "Could not connect to \(host)" : "Could not connect to \(host): \(result.stderr)")
        }
        var status = Status()
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "MACOS": status.macOS = parts[1]
            case "CLAUDE": status.claudeVersion = parts[1].isEmpty ? nil : parts[1]
            case "SB_HASH":
                status.seatbayInstalled = true
                status.seatbayCurrent = parts[1] == localBuildHash
            case "INSTANCE": status.instanceNames.append(parts[1])
            case "BYPASS": status.bypassDefault = parts[1]
            case "SB_RUNNING": status.seatbayRunning = true
            default: break
            }
        }
        return status
    }

    /// Copies this Seatbay.app to ~/Applications on the other Mac (restarting it there if it was open).
    /// Refuses while that Mac is in the middle of a safe update or a backup round.
    static func installSeatbay(host: String) throws {
        let bundle = Bundle.main.bundleURL
        let data = try packageBundle(bundle)
        let script = """
        set -e
        SUP="$HOME/Library/Application Support/Seatbay"
        [ -d "$SUP" ] || SUP="$HOME/Library/Application Support/MultiClaude"
        if [ -f "$SUP/update-in-progress" ]; then echo "BUSY: a safe update is running there" >&2; exit 3; fi
        if [ -f "$SUP/.backup-round.lock" ] && ! /usr/bin/lockf -t 0 "$SUP/.backup-round.lock" true 2>/dev/null; then
          echo "BUSY: a backup round is running there" >&2; exit 3
        fi
        WAS_RUNNING=0
        if pgrep -f "Contents/MacOS/(Seatbay|MultiClaude)$" >/dev/null; then
          WAS_RUNNING=1; pkill -TERM -f "Contents/MacOS/(Seatbay|MultiClaude)$" || true
          for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Contents/MacOS/(Seatbay|MultiClaude)$" >/dev/null || break; sleep 1; done
        fi
        mkdir -p "$HOME/Applications"
        T="$HOME/Applications/.seatbay-incoming"
        rm -rf "$T"; mkdir -p "$T"; tar -C "$T" -xf -
        rm -rf "\(remoteApp)"; mv "$T/\(bundle.lastPathComponent)" "\(remoteApp)"; rm -rf "$T"
        rm -rf "\(legacyRemoteApp)"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(remoteApp)" || true
        codesign -v "\(remoteApp)"
        if [ "$WAS_RUNNING" = 1 ]; then open "\(remoteApp)"; fi
        echo INSTALLED
        """
        let result = ssh(host, script, input: data)
        guard result.status == 0, result.stdout.contains("INSTALLED") else {
            throw Failure(message: "Installing on \(host) failed: \(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)")
        }
    }

    private static func packageBundle(_ bundle: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-C", bundle.deletingLastPathComponent().path, "-cf", "-", bundle.lastPathComponent]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "Could not package Seatbay") }
        return data
    }

    /// Sends instance profiles; the other Mac creates or updates them with its own Claude and icons.
    static func copyProfiles(_ instances: [Instance], host: String) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(instances.map(InstanceProfile.init))
        let result = ssh(host, "\"\(remoteBinary)\" --import-profiles -", input: data)
        guard result.status == 0 else {
            throw Failure(message: result.stderr.isEmpty ? "The other Mac couldn't import the profiles (exit \(result.status))" : result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
