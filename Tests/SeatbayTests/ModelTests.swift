import XCTest
@testable import Seatbay

final class ModelTests: XCTestCase {
    private func instance(dataDir: String) -> Instance {
        Instance(id: UUID(), name: "Work", number: 2, colorName: "Blue", style: .colorAndNumber, label: "",
                 dataDir: dataDir, createdAt: Date())
    }

    func testAccountAndAPIFolders() {
        let account = instance(dataDir: "/x/Instances/ABC")
        XCTAssertFalse(account.usesAPI)
        XCTAssertEqual(account.apiDataDir, "/x/Instances/ABC-3p")
        let api = instance(dataDir: "/x/Instances/ABC-3p")
        XCTAssertTrue(api.usesAPI)
        XCTAssertEqual(api.accountDataDir, "/x/Instances/ABC")
        XCTAssertEqual(api.apiDataDir, "/x/Instances/ABC-3p")
    }

    func testNames() {
        XCTAssertNotNil(Instance.nameProblem(""))
        XCTAssertNotNil(Instance.nameProblem(" claude "))
        XCTAssertNotNil(Instance.nameProblem(String(repeating: "a", count: 61)))
        XCTAssertNil(Instance.nameProblem("Claude Work"))
        XCTAssertEqual(Instance.fileSafe("a/b:c"), "a-b-c")
        XCTAssertEqual(Instance.fileSafe("   "), "Claude Instance")
    }

    func testMainRestoreGoesBackToItsOwnKindOfFolder() {
        let main = ClaudeTarget(id: ClaudeTarget.mainID, name: "Claude (main)", number: 1, colorName: nil,
                                dataDir: URL(fileURLWithPath: "/Users/x/Library/Application Support/Claude"), instance: nil)
        var info = SnapshotInfo(id: "s", targetID: "main", targetName: "Claude (main)", number: 1, colorName: nil, style: nil,
                                label: nil, createdAt: Date(), reason: "test", claudeVersion: "1", bytes: 0, sha256: "",
                                machine: "m", uploadedAt: nil)
        XCTAssertEqual(main.forRestore(of: info).dataDir.lastPathComponent, "Claude")   // unknown: as it is
        info.usesAPI = true
        XCTAssertEqual(main.forRestore(of: info).dataDir.lastPathComponent, "Claude-3p")
        info.usesAPI = false
        XCTAssertEqual(main.forRestore(of: info).dataDir.lastPathComponent, "Claude")
    }

    func testSettingsFileFillsDefaultsAndKeepsDates() throws {
        struct Sample: Codable, Equatable {
            var name = "default"
            var count = 3
            var when: Date?
        }
        let stored = Data(#"{"name":"stored","when":"2026-11-18T10:34:48Z"}"#.utf8)
        let decoded = JSONFile.decode(stored, defaults: Sample())
        XCTAssertEqual(decoded.name, "stored")
        XCTAssertEqual(decoded.count, 3)
        XCTAssertNotNil(decoded.when)
        let list = JSONFile.decode(Data(#"[1,2,3]"#.utf8), defaults: [Int]())
        XCTAssertEqual(list, [1, 2, 3])
    }

    func testHostsThatLookLikeOptionsAreRefused() {
        XCTAssertNotNil(OtherMac.hostProblem("-oProxyCommand=touch /tmp/x"))
        XCTAssertNotNil(OtherMac.hostProblem("me@host; rm -rf ~"))
        XCTAssertNotNil(OtherMac.hostProblem(""))
        XCTAssertNil(OtherMac.hostProblem("me@studio.local"))
    }
}
