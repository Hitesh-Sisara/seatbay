import CryptoKit
import Foundation

/// Minimal S3 client (AWS Signature Version 4) for any S3-compatible storage:
/// AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO, DigitalOcean Spaces …
struct S3Client {
    struct Object: Hashable {
        var key: String
        var size: Int64
        var lastModified: Date?
    }

    struct S3Error: LocalizedError {
        var status: Int
        var code: String
        var message: String
        var errorDescription: String? {
            "S3 error \(status)\(code.isEmpty ? "" : " \(code)")\(message.isEmpty ? "" : ": \(message)")"
        }
    }

    let endpoint: URL
    let region: String
    let bucket: String
    let pathStyle: Bool
    let accessKeyID: String
    let secretAccessKey: String
    var session: URLSession = .shared

    init(settings: S3Settings, secrets: BackupSecrets) throws {
        var raw = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), url.host != nil else {
            throw S3Error(status: 0, code: "", message: "The endpoint “\(settings.endpoint)” is not a valid URL")
        }
        guard !secrets.accessKeyID.isEmpty, !secrets.secretAccessKey.isEmpty else {
            throw S3Error(status: 0, code: "", message: "Enter the access key ID and secret access key")
        }
        endpoint = url
        region = settings.region.isEmpty ? "us-east-1" : settings.region
        bucket = settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        pathStyle = settings.pathStyle
        accessKeyID = secrets.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        secretAccessKey = secrets.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Operations

    func put(_ key: String, data: Data) async throws {
        _ = try await send("PUT", key: key, body: data)
    }

    func get(_ key: String) async throws -> Data {
        try await send("GET", key: key)
    }

    func delete(_ key: String) async throws {
        _ = try await send("DELETE", key: key)
    }

    func list(prefix: String) async throws -> [Object] {
        var objects: [Object] = []
        var token: String?
        repeat {
            var query = ["list-type": "2", "prefix": prefix]
            if let token { query["continuation-token"] = token }
            let data = try await send("GET", key: nil, query: query)
            let page = ListParser.parse(data)
            objects += page.objects
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
        return objects
    }

    // MARK: Signing

    private func send(_ method: String, key: String?, query: [String: String] = [:], body: Data = Data()) async throws -> Data {
        var path = endpoint.path
        var host = endpoint.host!
        if pathStyle {
            path += "/" + Self.encode(bucket, keepSlash: false)
        } else {
            host = "\(bucket).\(host)"
        }
        if let key { path += "/" + Self.encode(key, keepSlash: true) } else if !pathStyle || path.isEmpty { path += "/" }
        if path.isEmpty { path = "/" }

        let canonicalQuery = query.sorted { $0.key < $1.key }
            .map { "\(Self.encode($0.key, keepSlash: false))=\(Self.encode($0.value, keepSlash: false))" }
            .joined(separator: "&")

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = host
        components.port = endpoint.port
        components.percentEncodedPath = path
        if !canonicalQuery.isEmpty { components.percentEncodedQuery = canonicalQuery }
        guard let url = components.url else { throw S3Error(status: 0, code: "", message: "Could not build the request URL") }

        let defaultPort = endpoint.scheme == "https" ? 443 : 80
        let hostHeader = endpoint.port.map { $0 == defaultPort ? host : "\(host):\($0)" } ?? host

        let now = Date()
        let amzDate = Self.format(now, "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = Self.format(now, "yyyyMMdd")
        let payloadHash = Self.hex(SHA256.hash(data: body))
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [method, path, canonicalQuery,
                                "host:\(hostHeader)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n",
                                signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))))"
        var key = Self.hmac(Data("AWS4\(secretAccessKey)".utf8), dateStamp)
        for part in [region, "s3", "aws4_request"] { key = Self.hmac(key, part) }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: key)))

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        if method == "PUT" { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }

        let (data, response) = method == "PUT"
            ? try await session.upload(for: request, from: body)
            : try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let parsed = ErrorParser.parse(data)
            throw S3Error(status: status, code: parsed.code, message: parsed.message)
        }
        return data
    }

    private static func encode(_ string: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: XML

    private final class ListParser: NSObject, XMLParserDelegate {
        var objects: [Object] = []
        var isTruncated = false
        var nextToken: String?
        private var text = ""
        private var current: Object?
        private let iso = ISO8601DateFormatter()

        static func parse(_ data: Data) -> ListParser {
            let delegate = ListParser()
            delegate.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "Contents" { current = Object(key: "", size: 0, lastModified: nil) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "Key": current?.key = text
            case "Size": current?.size = Int64(text) ?? 0
            case "LastModified":
                current?.lastModified = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            case "Contents": if let current { objects.append(current) }; current = nil
            case "IsTruncated": isTruncated = text == "true"
            case "NextContinuationToken": nextToken = text
            default: break
            }
        }
    }

    private final class ErrorParser: NSObject, XMLParserDelegate {
        var code = "", message = ""
        private var text = ""

        static func parse(_ data: Data) -> (code: String, message: String) {
            let delegate = ErrorParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return (delegate.code, delegate.message)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) { text = "" }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Code" { code = text }
            if name == "Message" { message = text }
        }
    }
}

/// Encrypted copies of snapshots in S3:
///
///     <prefix>/<machine>/<target id>/<snapshot id>.mcb        encrypted .tar.gz
///     <prefix>/<machine>/<target id>/<snapshot id>.meta.mcb   encrypted SnapshotInfo JSON (names, colour, version)
enum S3Backup {
    struct Remote: Identifiable, Hashable {
        var machine: String
        var targetID: String
        var snapshotID: String
        var size: Int64
        var lastModified: Date?
        var id: String { "\(machine)/\(targetID)/\(snapshotID)" }
    }

    static func client() throws -> (S3Client, S3Settings, BackupSecrets) {
        let settings = SettingsFile.load().s3
        let secrets = SettingsFile.loadSecrets()
        guard settings.isConfigured else {
            throw S3Client.S3Error(status: 0, code: "", message: "Set the S3 endpoint and bucket first")
        }
        guard !secrets.passphrase.isEmpty else { throw BackupCrypto.CryptoError.noPassphrase }
        return (try S3Client(settings: settings, secrets: secrets), settings, secrets)
    }

    static func base(_ settings: S3Settings, machine: String, targetID: String) -> String {
        let prefix = settings.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return (prefix.isEmpty ? "" : prefix + "/") + "\(machine)/\(targetID)/"
    }

    /// A single PUT is limited to 5 GB on S3 and R2; backups are normally a few MB.
    static let maxUploadBytes: Int64 = 4_500_000_000

    static func upload(_ info: SnapshotInfo) async throws {
        let (client, settings, secrets) = try client()
        let size = (try? FileManager.default.attributesOfItem(atPath: Snapshots.archiveURL(info).path)[.size] as? Int64) ?? info.bytes
        guard size <= maxUploadBytes else {
            throw S3Client.S3Error(status: 0, code: "", message: "\(info.targetName)'s backup is \(ByteFormat.file(UInt64(size))), over the 4.5 GB a single upload allows; it stays on this Mac")
        }
        let archive = try Data(contentsOf: Snapshots.archiveURL(info))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var meta = info
        meta.uploadedAt = nil
        let base = base(settings, machine: info.machine, targetID: info.targetID)
        try await client.put(base + "\(info.id).mcb", data: try BackupCrypto.encrypt(archive, passphrase: secrets.passphrase))
        try await client.put(base + "\(info.id).meta.mcb",
                             data: try BackupCrypto.encrypt(try encoder.encode(meta), passphrase: secrets.passphrase))
        var updated = info
        updated.uploadedAt = Date()
        try Snapshots.saveSidecar(updated)
        try await pruneRemote(client: client, settings: settings, machine: info.machine, targetID: info.targetID)
    }

    static func pruneRemote(client: S3Client, settings: S3Settings, machine: String, targetID: String) async throws {
        let base = base(settings, machine: machine, targetID: targetID)
        let archives = try await client.list(prefix: base)
            .filter { $0.key.hasSuffix(".mcb") && !$0.key.hasSuffix(".meta.mcb") }
            .sorted { $0.key > $1.key }   // ids start with a timestamp
        for old in archives.dropFirst(max(1, settings.keepRemote)) {
            let stem = String(old.key.dropLast(4))
            try await client.delete(old.key)
            try? await client.delete(stem + ".meta.mcb")
            // The local copy is no longer in S3.
            let snapshotID = String(stem.split(separator: "/").last ?? "")
            if var local = Snapshots.list(targetID: targetID).first(where: { $0.id == snapshotID }), local.uploadedAt != nil {
                local.uploadedAt = nil
                local.prunedFromRemote = true   // so "upload what's missing" doesn't send it back
                try? Snapshots.saveSidecar(local)
            }
        }
    }

    static func listRemote() async throws -> [Remote] {
        let (client, settings, _) = try client()
        let prefix = settings.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let root = prefix.isEmpty ? "" : prefix + "/"
        return try await client.list(prefix: root).compactMap { object -> Remote? in
            guard object.key.hasSuffix(".mcb"), !object.key.hasSuffix(".meta.mcb") else { return nil }
            let parts = object.key.dropFirst(root.count).split(separator: "/")
            guard parts.count == 3 else { return nil }
            return Remote(machine: String(parts[0]), targetID: String(parts[1]), snapshotID: String(parts[2].dropLast(4)),
                          size: object.size, lastModified: object.lastModified)
        }.sorted { $0.snapshotID > $1.snapshotID }
    }

    static func metadata(_ remote: Remote) async throws -> SnapshotInfo {
        let (client, settings, secrets) = try client()
        let key = base(settings, machine: remote.machine, targetID: remote.targetID) + "\(remote.snapshotID).meta.mcb"
        let plain = try BackupCrypto.decrypt(try await client.get(key), passphrase: secrets.passphrase)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SnapshotInfo.self, from: plain)
    }

    /// Downloads and decrypts a remote backup into a temporary .tar.gz file.
    static func download(_ remote: Remote) async throws -> URL {
        let (client, settings, secrets) = try client()
        let key = base(settings, machine: remote.machine, targetID: remote.targetID) + "\(remote.snapshotID).mcb"
        let plain = try BackupCrypto.decrypt(try await client.get(key), passphrase: secrets.passphrase)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mc-restore-\(UUID().uuidString).tar.gz")
        FileManager.default.createFile(atPath: file.path, contents: plain, attributes: [.posixPermissions: 0o600])
        return file
    }

    /// Writes, reads back and deletes a small test object.
    static func testConnection(settings: S3Settings, secrets: BackupSecrets) async throws {
        let client = try S3Client(settings: settings, secrets: secrets)
        let prefix = settings.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let key = (prefix.isEmpty ? "" : prefix + "/") + ".seatbay-connection-test"
        let payload = Data("multi claude \(Date())".utf8)
        try await client.put(key, data: payload)
        let echoed = try await client.get(key)
        try await client.delete(key)
        guard echoed == payload else {
            throw S3Client.S3Error(status: 0, code: "", message: "The test object came back different")
        }
        _ = try await client.list(prefix: prefix.isEmpty ? "" : prefix + "/")
    }
}
