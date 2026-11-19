import XCTest
@testable import Seatbay

final class NightlyBackupTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testWindowStartIsTodayAfterTheHourAndYesterdayBefore() {
        XCTAssertEqual(NightlyBackup.windowStart(before: date(18, 10), hour: 2, calendar: calendar), date(18, 2))
        XCTAssertEqual(NightlyBackup.windowStart(before: date(18, 2), hour: 2, calendar: calendar), date(18, 2))
        XCTAssertEqual(NightlyBackup.windowStart(before: date(18, 1, 59), hour: 2, calendar: calendar), date(17, 2))
    }

    func testOffMeansNeverDue() {
        var settings = AppSettings()
        settings.nightlyBackup = false
        guard case .no = NightlyBackup.due(now: Date(), settings: settings, state: .init()) else {
            return XCTFail("expected not due")
        }
    }

    func testDueInsideTheWindowAndCatchUpAfterIt() {
        var settings = AppSettings()
        settings.nightlyBackup = true
        settings.nightlyHour = Calendar.current.component(.hour, from: Date())
        // Inside the hour that just started: tonight's round.
        let start = NightlyBackup.windowStart(before: Date(), hour: settings.nightlyHour)
        XCTAssertEqual(NightlyBackup.due(now: start.addingTimeInterval(60), settings: settings, state: .init()), .tonight)
        // Two hours later with no round done: a catch-up.
        XCTAssertEqual(NightlyBackup.due(now: start.addingTimeInterval(7200), settings: settings, state: .init()), .catchUp)
    }

    func testNotDueOnceDoneOrWhileWaitingToRetry() {
        var settings = AppSettings()
        settings.nightlyBackup = true
        settings.nightlyHour = 2
        let start = NightlyBackup.windowStart(before: Date(), hour: 2)
        let now = start.addingTimeInterval(5 * 3600)
        var state = NightlyBackup.State()
        state.lastSuccess = start.addingTimeInterval(300)
        guard case .no = NightlyBackup.due(now: now, settings: settings, state: state) else { return XCTFail("done tonight") }

        state = NightlyBackup.State()
        state.lastAttempt = now.addingTimeInterval(-10 * 60)   // failed ten minutes ago
        guard case .no = NightlyBackup.due(now: now, settings: settings, state: state) else { return XCTFail("should wait") }
        state.lastAttempt = now.addingTimeInterval(-31 * 60)   // half an hour later: try again
        XCTAssertEqual(NightlyBackup.due(now: now, settings: settings, state: state), .catchUp)
    }

    func testAgentPlistRunsTheScheduledBackup() {
        let plist = NightlyBackup.agentPlist(executable: "/Applications/Seatbay.app/Contents/MacOS/Seatbay", hour: 2)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Applications/Seatbay.app/Contents/MacOS/Seatbay", "--scheduled-backup"])
        XCTAssertEqual((plist["StartCalendarInterval"] as? [String: Int])?["Hour"], 2)
        XCTAssertEqual(plist["StartInterval"] as? Int, 1800)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertTrue(NightlyBackup.isTranslocated("/private/var/folders/x/AppTranslocation/ABC/d/Seatbay.app/Contents/MacOS/Seatbay"))
        XCTAssertFalse(NightlyBackup.isTranslocated("/Applications/Seatbay.app/Contents/MacOS/Seatbay"))
    }
}
