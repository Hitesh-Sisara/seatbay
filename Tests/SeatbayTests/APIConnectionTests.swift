import XCTest
@testable import Seatbay

final class APIConnectionTests: XCTestCase {
    func testBaseURLIsTrimmedForClaude() {
        var api = APIConnection()
        api.baseURL = "  https://gateway.example.com/anthropic/v1/  "
        XCTAssertEqual(api.trimmedBaseURL, "https://gateway.example.com/anthropic")
        XCTAssertTrue(api.isGateway)
        XCTAssertEqual(api.endpointDescription, "gateway.example.com")
        api.baseURL = ""
        XCTAssertFalse(api.isGateway)
        XCTAssertEqual(api.endpointDescription, "Anthropic API")
    }

    func testGatewayEntryRoundTrips() {
        var api = APIConnection()
        api.baseURL = "https://gateway.example.com/ai"
        api.apiKey = " key-123 "
        api.authScheme = .bearer
        api.models = ["claude-opus-5-5", "claude-sonnet-5-5"]
        api.headers = ["X-Team": "infra"]
        let entry = api.entry
        XCTAssertEqual(entry["inferenceProvider"] as? String, "gateway")
        XCTAssertEqual(entry["inferenceGatewayBaseUrl"] as? String, "https://gateway.example.com/ai")
        XCTAssertEqual(entry["inferenceGatewayApiKey"] as? String, "key-123")
        XCTAssertEqual(entry["inferenceGatewayAuthScheme"] as? String, "bearer")
        let back = APIConnection(entry: entry)
        XCTAssertEqual(back?.trimmedBaseURL, api.trimmedBaseURL)
        XCTAssertEqual(back?.trimmedKey, "key-123")
        XCTAssertEqual(back?.authScheme, .bearer)
        XCTAssertEqual(back?.models, api.models)
        XCTAssertEqual(back?.headers, api.headers)
    }

    func testAnthropicKeyEntry() {
        var api = APIConnection()
        api.apiKey = "sk-ant-test"
        XCTAssertEqual(api.entry["inferenceProvider"] as? String, "anthropic")
        XCTAssertEqual(api.entry["inferenceAnthropicApiKey"] as? String, "sk-ant-test")
        XCTAssertNil(api.entry["inferenceGatewayBaseUrl"])
        XCTAssertNil(APIConnection(entry: ["inferenceProvider": "vertex"]))
    }

    func testProblems() {
        var api = APIConnection()
        XCTAssertNotNil(api.problem)                     // no key
        api.apiKey = "k"
        XCTAssertNil(api.problem)
        api.baseURL = "gateway.example.com"
        XCTAssertNotNil(api.problem)                     // no scheme
        api.baseURL = "https://gateway.example.com"
        api.headers = ["Bad Header": "x"]
        XCTAssertNotNil(api.problem)
        api.headers = ["X-Ok": "line\nbreak"]
        XCTAssertNotNil(api.problem)
    }

    func testTextForms() {
        var api = APIConnection()
        api.modelsText = "claude-opus-5-5, claude-haiku-5-5\nkimi-k3"
        XCTAssertEqual(api.models, ["claude-opus-5-5", "claude-haiku-5-5", "kimi-k3"])
        api.headersText = "X-One: 1\nX-Two:  two words \n\n"
        XCTAssertEqual(api.headers, ["X-One": "1", "X-Two": "two words"])
        XCTAssertEqual(api.headersText, "X-One: 1\nX-Two: two words")
    }

    func testSealedKeysAreRecognisedAndNotTested() async {
        var api = APIConnection()
        api.apiKey = "__seal:abc"
        XCTAssertTrue(api.isSealed)
        let result = await api.test()
        XCTAssertFalse(result.ok)
    }

    func testConfigFileSaveLoadAndDisable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seatbay-test-\(UUID().uuidString)-3p")
        defer { try? FileManager.default.removeItem(at: dir) }
        var api = APIConnection()
        api.baseURL = "https://gateway.example.com"
        api.apiKey = "k1"
        try APIConfigFile.save(api, dataDir: dir, name: "Test")
        XCTAssertEqual(APIConfigFile.load(dataDir: dir)?.trimmedKey, "k1")
        let attributes = try FileManager.default.attributesOfItem(atPath: APIConfigFile.metaURL(dir).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Saving again keeps the same entry and anything Claude added to it.
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: APIConfigFile.metaURL(dir))) as? [String: Any]
        let id = try XCTUnwrap(meta?["appliedId"] as? String)
        let entryURL = APIConfigFile.library(dir).appendingPathComponent("\(id).json")
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any])
        entry["coworkEgressAllowedHosts"] = ["*"]
        try JSONSerialization.data(withJSONObject: entry).write(to: entryURL)
        api.apiKey = "k2"
        try APIConfigFile.save(api, dataDir: dir, name: "Test")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any])
        XCTAssertEqual(saved["inferenceGatewayApiKey"] as? String, "k2")
        XCTAssertEqual(saved["coworkEgressAllowedHosts"] as? [String], ["*"])

        try APIConfigFile.disable(dataDir: dir)
        XCTAssertNil(APIConfigFile.load(dataDir: dir))
        XCTAssertEqual(APIConfigFile.loadDisabled(dataDir: dir)?.trimmedKey, "k2")
    }
}
