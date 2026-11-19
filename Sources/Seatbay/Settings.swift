import Foundation
import SeatbayCore

/// Seatbay's own preferences (~/Library/Application Support/Seatbay/settings.json).
/// Every field has a default, so older or partial files still load.
struct AppSettings: Codable, Equatable {
    // Safe updates
    var safeUpdates = false
    var autoInstallWhenIdle = true
    var autoInstallPaused = false        // set after a rollback so the newer build isn't reinstalled at once
    var keepPreviousVersion = true

    // Sleep
    var sleepEnabled = false
    var sleepAfterMinutes = 30

    // Backups
    var backupOnQuit = true
    var backupMinIntervalHours = 6
    var keepLocalSnapshots = 10
    var s3 = S3Settings()
    /// Back up every Claude each night (open ones too, from a clone) and upload what isn't in S3 yet.
    /// A round missed because the Mac was asleep or off, or one that failed, is caught up during the day.
    var nightlyBackup = false
    /// The one-time "Back up every Claude each night?" question has been answered.
    var nightlyPromptAnswered = false
    /// The window starts at this hour (local time) and lasts an hour.
    var nightlyHour = 2

    // Other Mac
    var otherMacHost = ""
}

struct S3Settings: Codable, Equatable {
    var enabled = false
    var endpoint = ""          // e.g. https://s3.us-east-1.amazonaws.com, https://<account>.r2.cloudflarestorage.com
    var region = "us-east-1"   // "auto" for Cloudflare R2
    var bucket = ""
    var prefix = "seatbay"
    var pathStyle = true       // MinIO and most S3-compatible services need path-style URLs
    var keepRemote = 30

    var isConfigured: Bool { !endpoint.isEmpty && !bucket.isEmpty }
}

/// Secrets for S3 backups, kept in a 0600 file next to the settings (like ~/.aws/credentials).
/// The Keychain isn't used because an ad-hoc signed app gets a new code identity on every rebuild,
/// which would make macOS ask for the keychain password again each time.
struct BackupSecrets: Codable, Equatable {
    var accessKeyID = ""
    var secretAccessKey = ""
    var passphrase = ""
}

enum JSONFile {
    /// Decodes `data`, filling any missing keys from `defaults`.
    static func decode<T: Codable>(_ data: Data, defaults: T) -> T {
        // Same date format as `save` writes.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let defaultData = try? encoder.encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Not an object (a list, say): nothing to merge, decode it as it is.
            return (try? decoder.decode(T.self, from: data)) ?? defaults
        }
        merge(&merged, with: stored)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return defaults }
        return (try? decoder.decode(T.self, from: mergedData)) ?? defaults
    }

    private static func merge(_ base: inout [String: Any], with overlay: [String: Any]) {
        for (key, value) in overlay {
            if var nested = base[key] as? [String: Any], let overlayNested = value as? [String: Any] {
                merge(&nested, with: overlayNested)
                base[key] = nested
            } else {
                base[key] = value
            }
        }
    }

    static func load<T: Codable>(_ url: URL, defaults: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return defaults }
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            // Damaged: keep a copy before anything can overwrite it (secrets.json holds the backup passphrase).
            keepAside(url)
            return defaults
        }
        return decode(data, defaults: defaults)
    }

    /// Copies an unreadable file to "<name>.unreadable-<date>" next to it, readable only by the user.
    static func keepAside(_ url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"   // at most one copy a day
        let aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).unreadable-\(formatter.string(from: Date()))")
        guard !FileManager.default.fileExists(atPath: aside.path) else { return }
        try? FileManager.default.copyItem(at: url, to: aside)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
    }

    static func save<T: Encodable>(_ value: T, to url: URL, privateFile: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if privateFile {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "Seatbay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)"])
            }
            if rename(temp.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temp)
                throw NSError(domain: "Seatbay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not replace \(url.lastPathComponent)"])
            }
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

enum SettingsFile {
    static var url: URL { SB.supportDir.appendingPathComponent("settings.json") }
    static var secretsURL: URL { SB.supportDir.appendingPathComponent("secrets.json") }

    static func load() -> AppSettings { JSONFile.load(url, defaults: AppSettings()) }
    static func save(_ settings: AppSettings) throws { try JSONFile.save(settings, to: url) }

    static func loadSecrets() -> BackupSecrets { JSONFile.load(secretsURL, defaults: BackupSecrets()) }
    static func saveSecrets(_ secrets: BackupSecrets) throws { try JSONFile.save(secrets, to: secretsURL, privateFile: true) }
}
