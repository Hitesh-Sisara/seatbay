import Foundation
import JavaScriptCore

/// Reads and writes `permissions.defaultMode` in ~/.claude/settings.json.
///
/// Claude Desktop has no environment variable for the default permission mode of new Code
/// sessions; it reads `permissions.defaultMode` from the Claude Code settings files (user, project,
/// local, managed). The user file is shared by the main Claude, every instance and the terminal
/// `claude` CLI, so one switch covers them all. Project files are not allowed to default to bypass.
///
/// The file usually holds much more (env, hooks, API keys), so edits go through JavaScriptCore's
/// JSON, which keeps key order, and the file stays 0600.
enum ClaudeCodeSettings {
    static let bypassMode = "bypassPermissions"

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func defaultMode(at url: URL = url) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["permissions"] as? [String: Any])?["defaultMode"] as? String
    }

    static var bypassByDefault: Bool { defaultMode() == bypassMode }

    static func setBypassByDefault(_ enabled: Bool, at link: URL = url) throws {
        let fm = FileManager.default
        // Dotfile managers often make settings.json a symlink: edit the file it points to, keep the link.
        let url = link.resolvingSymlinksInPath()
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
        let exists = fm.fileExists(atPath: url.path)
        let original = exists ? try String(contentsOf: url, encoding: .utf8) : "{}"

        guard let context = JSContext() else { throw failure("JavaScriptCore is unavailable") }
        var scriptError: String?
        context.exceptionHandler = { _, exception in scriptError = exception?.toString() }
        context.setObject(original, forKeyedSubscript: "source" as NSString)
        context.setObject(enabled, forKeyedSubscript: "enable" as NSString)
        let result = context.evaluateScript("""
            (function () {
              var o = JSON.parse(source);
              if (o === null || typeof o !== 'object' || Array.isArray(o)) throw new Error('it is not a JSON object');
              if (enable) {
                if (!o.permissions || typeof o.permissions !== 'object') o.permissions = {};
                o.permissions.defaultMode = 'bypassPermissions';
              } else if (o.permissions && o.permissions.defaultMode === 'bypassPermissions') {
                delete o.permissions.defaultMode;
                if (Object.keys(o.permissions).length === 0) delete o.permissions;
              }
              return JSON.stringify(o, null, 2);
            })()
            """)
        if let scriptError { throw failure("~/.claude/settings.json could not be read (\(scriptError)). Nothing was changed.") }
        guard let text = result?.toString(), !text.isEmpty, text != "undefined" else {
            throw failure("~/.claude/settings.json could not be updated. Nothing was changed.")
        }

        // One-time safety copy of the user's file before Seatbay first edits it.
        let backup = url.appendingPathExtension("seatbay-backup")
        if exists, !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: url, to: backup) }

        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = text + (original.hasSuffix("\n") || !exists ? "\n" : "")
        let temp = url.deletingLastPathComponent().appendingPathComponent(".settings.json.seatbay-\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: Data(output.utf8), attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw failure("Could not write next to ~/.claude/settings.json.")
        }
        if rename(temp.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw failure("Could not replace ~/.claude/settings.json: \(reason)")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Seatbay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
