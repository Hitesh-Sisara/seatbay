import Foundation

/// How an instance reaches Claude when it uses an API key instead of a Claude account sign-in:
/// Anthropic's own API, or any Anthropic-compatible gateway (a base URL that serves /v1/messages).
///
/// Claude Desktop calls this "third-party inference". At start-up it looks for
/// `<data folder>-3p/configLibrary/_meta.json`; when the entry named by `appliedId` names a provider,
/// Claude switches to that "-3p" folder and talks to the provider instead of claude.ai. If the data
/// folder's own name already ends in "-3p", Claude uses it as it is. So an API instance simply gets a
/// data folder ending in "-3p", and Seatbay writes the entry the way Claude's own setup window does.
/// The key stays in that entry (a 0600 file inside the instance's data folder), like a sign-in does.
struct APIConnection: Equatable {
    enum AuthScheme: String, CaseIterable, Identifiable {
        case xAPIKey = "x-api-key"
        case bearer

        var id: String { rawValue }
        var title: String { self == .xAPIKey ? "x-api-key header" : "Authorization: Bearer" }
    }

    /// Empty means Anthropic's API (api.anthropic.com).
    var baseURL = ""
    var apiKey = ""
    var authScheme: AuthScheme = .xAPIKey
    /// Model ids offered in Claude's model menu. Empty: Claude's own list.
    var models: [String] = []
    /// Extra headers sent with every model request (gateway routing, team tags and so on).
    var headers: [String: String] = [:]

    static let anthropicAPI = "https://api.anthropic.com"

    var trimmedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        // Claude adds /v1/messages itself.
        if url.hasSuffix("/v1") { url.removeLast(3) }
        return url
    }

    var isGateway: Bool { !trimmedBaseURL.isEmpty }
    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Claude encrypts the key in place the first time it starts ("__seal…", decrypted with a key in the
    /// macOS keychain). Such a key works for Claude on this Mac but can't be read or tested from here.
    var isSealed: Bool { trimmedKey.hasPrefix("__seal") }

    /// Where requests go, for display.
    var endpointDescription: String {
        guard isGateway else { return "Anthropic API" }
        return URL(string: trimmedBaseURL)?.host ?? trimmedBaseURL
    }

    /// A user-facing problem with these settings, or nil when they can be saved.
    var problem: String? {
        if trimmedKey.isEmpty { return "Enter the API key." }
        if trimmedKey.contains(where: \.isNewline) { return "The API key can't contain line breaks." }
        if isGateway {
            guard let url = URL(string: trimmedBaseURL), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host?.isEmpty == false else {
                return "The base URL must start with https:// (for example https://gateway.example.com/anthropic)."
            }
        }
        for (name, value) in headers {
            if name.isEmpty || name.contains(where: { !($0.isLetter || $0.isNumber || "-_".contains($0)) }) {
                return "“\(name)” isn't a valid header name."
            }
            if value.contains(where: \.isNewline) { return "The value of \(name) can't contain line breaks." }
        }
        return nil
    }

    /// Settings keys Claude reads for third-party inference. Every key that starts with "inference" is
    /// Seatbay's to rewrite; anything else in the entry (written by Claude itself) is kept.
    var entry: [String: Any] {
        var entry: [String: Any] = [:]
        if isGateway {
            entry["inferenceProvider"] = "gateway"
            entry["inferenceGatewayBaseUrl"] = trimmedBaseURL
            entry["inferenceGatewayApiKey"] = trimmedKey
            entry["inferenceGatewayAuthScheme"] = authScheme.rawValue
        } else {
            entry["inferenceProvider"] = "anthropic"
            entry["inferenceAnthropicApiKey"] = trimmedKey
        }
        if !models.isEmpty { entry["inferenceModels"] = models }
        if !headers.isEmpty { entry["inferenceCustomHeaders"] = headers }
        return entry
    }

    init() {}

    init?(entry: [String: Any]) {
        switch entry["inferenceProvider"] as? String {
        case "gateway":
            baseURL = entry["inferenceGatewayBaseUrl"] as? String ?? ""
            apiKey = entry["inferenceGatewayApiKey"] as? String ?? ""
            authScheme = AuthScheme(rawValue: entry["inferenceGatewayAuthScheme"] as? String ?? "") ?? .bearer
        case "anthropic":
            apiKey = entry["inferenceAnthropicApiKey"] as? String ?? ""
        default:
            return nil
        }
        models = (entry["inferenceModels"] as? [Any])?.compactMap { item in
            (item as? String) ?? ((item as? [String: Any])?["name"] as? String) ?? ((item as? [String: Any])?["id"] as? String)
        } ?? []
        headers = entry["inferenceCustomHeaders"] as? [String: String] ?? [:]
    }

    // MARK: Text forms used by the editor and the command line

    var modelsText: String {
        get { models.joined(separator: ", ") }
        set {
            models = newValue.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
                .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    var headersText: String {
        get { headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n") }
        set {
            var parsed: [String: String] = [:]
            for line in newValue.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else {
                    let name = line.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { parsed[name] = "" }
                    continue
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { parsed[name] = value }
            }
            headers = parsed
        }
    }

    // MARK: Connection test

    /// Asks the API for its model list (free, no tokens used) to check the address and the key.
    func test() async -> (ok: Bool, message: String) {
        if isSealed {
            return (false, "Claude has sealed the saved key in the keychain, so it can't be tested from here. Type the key again to test it.")
        }
        let base = isGateway ? trimmedBaseURL : Self.anthropicAPI
        guard let url = URL(string: base + "/v1/models?limit=100") else { return (false, "The base URL isn't valid.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if isGateway && authScheme == .bearer {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
                    .compactMap { $0["id"] as? String } ?? []
                guard !ids.isEmpty else { return (true, "Connected. The key was accepted.") }
                let missing = models.filter { !ids.contains($0) }
                if !missing.isEmpty {
                    return (true, "Connected, but \(missing.joined(separator: ", ")) \(missing.count == 1 ? "isn't" : "aren't") in its model list (\(ids.count) models).")
                }
                return (true, "Connected. \(ids.count) model\(ids.count == 1 ? "" : "s") available, e.g. \(ids.prefix(3).joined(separator: ", ")).")
            case 401, 403:
                return (false, "The key was refused (HTTP \(status)).\(isGateway && authScheme == .bearer ? " Try the x-api-key header." : isGateway ? " Try Authorization: Bearer." : "")")
            case 404:
                return (true, "Reached \(endpointDescription), but it doesn't offer /v1/models, so the key couldn't be checked here. Claude will still use it.")
            default:
                let body = String(decoding: data.prefix(200), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                return (false, "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

/// Reads and writes Claude's third-party inference settings in a data folder.
enum APIConfigFile {
    static let folderSuffix = "-3p"

    static func library(_ dataDir: URL) -> URL { dataDir.appendingPathComponent("configLibrary", isDirectory: true) }
    static func metaURL(_ dataDir: URL) -> URL { library(dataDir).appendingPathComponent("_meta.json") }

    /// The connection Claude will use from this data folder, or nil when none is applied.
    static func load(dataDir: URL) -> APIConnection? {
        guard let entry = appliedEntry(dataDir: dataDir)?.entry else { return nil }
        return APIConnection(entry: entry)
    }

    private static func appliedEntry(dataDir: URL) -> (id: String, entry: [String: Any])? {
        guard let meta = readJSON(metaURL(dataDir)), let id = meta["appliedId"] as? String, isSafeID(id),
              let entry = readJSON(library(dataDir).appendingPathComponent("\(id).json")) else { return nil }
        return (id, entry)
    }

    /// Writes `connection` as the applied entry, keeping whatever else Claude stored in the entry.
    static func save(_ connection: APIConnection, dataDir: URL, name: String) throws {
        let fm = FileManager.default
        let lib = library(dataDir)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var meta = readJSON(metaURL(dataDir)) ?? [:]
        let existing = appliedEntry(dataDir: dataDir)
        let id = existing?.id ?? UUID().uuidString.lowercased()
        var entry = (existing?.entry ?? [:]).filter { !$0.key.hasPrefix("inference") }
        entry.merge(connection.entry) { _, new in new }
        try writeJSON(entry, to: lib.appendingPathComponent("\(id).json"))

        let label = "Seatbay: \(name)"
        var entries = (meta["entries"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != id }
        entries.insert(["id": id, "name": label], at: 0)
        meta["entries"] = entries
        meta["appliedId"] = id
        try writeJSON(meta, to: metaURL(dataDir))

        // Settings put aside by an earlier switch to a Claude account are superseded now.
        try? fm.removeItem(at: dataDir.appendingPathComponent("configLibrary.disabled-by-multi-claude", isDirectory: true))

        // A folder that was told to stay on a Claude account ("1p") would ignore the entry.
        let desktopConfig = dataDir.appendingPathComponent("claude_desktop_config.json")
        if var config = readJSON(desktopConfig), config["deploymentMode"] as? String == "1p" {
            config["deploymentMode"] = "3p"
            try writeJSON(config, to: desktopConfig)
        }
    }

    /// Stops Claude from switching to this folder (used when an instance goes back to a Claude account).
    /// The settings are moved aside, not deleted, so switching back later can start from them.
    static func disable(dataDir: URL) throws {
        let lib = library(dataDir)
        guard FileManager.default.fileExists(atPath: lib.path) else { return }
        let aside = dataDir.appendingPathComponent("configLibrary.disabled-by-multi-claude", isDirectory: true)
        try? FileManager.default.removeItem(at: aside)
        try FileManager.default.moveItem(at: lib, to: aside)
    }

    /// Settings kept aside by `disable`, for pre-filling the editor.
    static func loadDisabled(dataDir: URL) -> APIConnection? {
        let aside = dataDir.appendingPathComponent("configLibrary.disabled-by-multi-claude", isDirectory: true)
        guard let meta = readJSON(aside.appendingPathComponent("_meta.json")), let id = meta["appliedId"] as? String, isSafeID(id),
              let entry = readJSON(aside.appendingPathComponent("\(id).json")) else { return nil }
        return APIConnection(entry: entry)
    }

    private static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
