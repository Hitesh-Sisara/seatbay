import AppKit
import Foundation
import SeatbayCore
import SwiftUI

/// One extra Claude: its own app bundle in ~/Applications, its own data folder, its own icon.
struct Instance: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var number: Int
    var colorName: String
    var style: IconStyle
    var label: String
    var dataDir: String
    var createdAt: Date
    /// Excluded from "Sleep idle instances".
    var neverSleep: Bool?

    var appURL: URL { SB.userApplicationsDir.appendingPathComponent("\(Self.fileSafe(name)).app", isDirectory: true) }

    /// An API instance (API key or gateway instead of a Claude account) keeps its data in a folder whose
    /// name ends in "-3p", the folder Claude itself uses for that mode (see APIConnection).
    var usesAPI: Bool { dataDir.hasSuffix(APIConfigFile.folderSuffix) }
    /// The folder used with a Claude account sign-in.
    var accountDataDir: String { usesAPI ? String(dataDir.dropLast(APIConfigFile.folderSuffix.count)) : dataDir }
    /// The folder used with an API key or a gateway.
    var apiDataDir: String { accountDataDir + APIConfigFile.folderSuffix }
    var color: NSColor { Palette.color(named: colorName) }
    var bundleIdentifier: String { SB.instanceBundleIDPrefix + id.uuidString.lowercased().prefix(8) }

    /// A problem with a name for a new instance regardless of the others, or nil.
    static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give this instance a name." }
        if trimmed.caseInsensitiveCompare("Claude") == .orderedSame { return "“Claude” is the main app's name. Try “Claude Work”." }
        if trimmed.count > 60 { return "Use a name of up to 60 characters." }
        return nil
    }

    static func fileSafe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Claude Instance" : cleaned
    }
}

/// Something Seatbay can back up, restore, update or watch: the main Claude or one instance.
struct ClaudeTarget: Identifiable, Hashable {
    static let mainID = "main"

    let id: String
    let name: String
    let number: Int
    let colorName: String?
    let dataDir: URL
    let instance: Instance?

    var isMain: Bool { instance == nil }
    /// Runs on an API key or a gateway instead of a Claude account.
    var usesAPI: Bool { instance?.usesAPI ?? SB.mainClaudeUsesAPIKey }

    static var main: ClaudeTarget {
        ClaudeTarget(id: mainID, name: "Claude (main)", number: 1, colorName: "Orange",
                     dataDir: SB.mainClaudeDataDir, instance: nil)
    }

    init(id: String, name: String, number: Int, colorName: String?, dataDir: URL, instance: Instance?) {
        self.id = id
        self.name = name
        self.number = number
        self.colorName = colorName
        self.dataDir = dataDir
        self.instance = instance
    }

    init(_ instance: Instance) {
        self.init(id: instance.id.uuidString, name: instance.name, number: instance.number, colorName: instance.colorName,
                  dataDir: URL(fileURLWithPath: instance.dataDir, isDirectory: true), instance: instance)
    }

    /// Where a backup should be restored. The main Claude has two folders (a Claude account in "Claude",
    /// an API key or cloud provider in "Claude-3p"); a backup goes back to the kind it was taken from.
    func forRestore(of info: SnapshotInfo) -> ClaudeTarget {
        guard isMain, let usesAPI = info.usesAPI else { return self }
        let folder = dataDir.deletingLastPathComponent().appendingPathComponent(usesAPI ? "Claude-3p" : "Claude", isDirectory: true)
        return ClaudeTarget(id: id, name: name, number: number, colorName: colorName, dataDir: folder, instance: nil)
    }

    /// The running main Claude process for this target, if any.
    func runningPID(claudeExecutable: String) -> pid_t? {
        let dir = isMain ? nil : SB.normalize(dataDir.path)
        return ProcessInspector.claudeProcesses(executablePath: claudeExecutable)
            .first { $0.dataDir == dir && !(isMain && $0.runsFromClone) }?.pid
    }
}

/// instances.json in ~/Library/Application Support/Seatbay.
enum InstanceFile {
    static var url: URL { SB.supportDir.appendingPathComponent("instances.json") }

    struct Unreadable: LocalizedError {
        var reason: String
        var errorDescription: String? {
            "instances.json couldn't be read (\(reason)), so Seatbay won't change it. Your instance apps and their data are untouched. Fix or restore the file, then reopen Seatbay."
        }
    }

    /// Set when instances.json exists but can't be decoded (damaged, or written by a newer Seatbay).
    /// While it's set, `save` refuses: saving would replace every instance with an empty list.
    nonisolated(unsafe) static var unreadable: Unreadable?

    static func load() -> [Instance] {
        guard let data = try? Data(contentsOf: url) else { unreadable = nil; return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let instances = try decoder.decode([Instance].self, from: data)
            unreadable = nil
            return instances
        } catch {
            unreadable = Unreadable(reason: (error as? DecodingError).map { "\($0)".prefix(160).description } ?? error.localizedDescription)
            return []
        }
    }

    static func save(_ instances: [Instance]) throws {
        if let unreadable { throw unreadable }
        try FileManager.default.createDirectory(at: SB.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(instances).write(to: url, options: .atomic)
    }
}

enum Palette {
    /// Distinct, Dock-friendly colours. "Orange" is Claude's own terracotta.
    static let entries: [(name: String, hex: UInt32)] = [
        ("Blue", 0x1E7BF2),
        ("Green", 0x2FA35B),
        ("Purple", 0x8B4FD6),
        ("Pink", 0xE0409A),
        ("Teal", 0x0FA3A3),
        ("Red", 0xE0383E),
        ("Amber", 0xF2A516),
        ("Indigo", 0x4253D6),
        ("Brown", 0x9A6A4F),
        ("Graphite", 0x5E5E66),
        ("Black", 0x1F1F22),
        ("Orange", 0xDA7756),
    ]

    static var names: [String] { entries.map(\.name) }

    static func color(named name: String) -> NSColor {
        let hex = entries.first { $0.name == name }?.hex ?? 0x1E7BF2
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func swiftUIColor(named name: String) -> Color { Color(nsColor: color(named: name)) }
}
