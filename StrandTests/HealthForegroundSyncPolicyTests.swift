import XCTest
@testable import Strand

final class HealthForegroundSyncPolicyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func decide(now: String, last: String?, full: String?, loaded: Bool = true) -> HealthForegroundSyncPolicy.Plan {
        HealthForegroundSyncPolicy.decide(now: at(now), lastRunAt: last.map(at), lastFullAt: full.map(at),
                                          repoLoaded: loaded, calendar: cal)
    }

    func testFirstRunIsFull() {
        let p = decide(now: "2026-11-20T10:00:00Z", last: nil, full: nil)
        XCTAssertEqual(p, .init(run: true, days: 30, isFull: true))
    }

    func testRepositoryNotLoadedAlwaysRunsFull() {
        let p = decide(now: "2026-11-20T10:01:00Z", last: "2026-11-20T10:00:00Z", full: "2026-11-20T10:00:00Z", loaded: false)
        XCTAssertEqual(p, .init(run: true, days: 30, isFull: true))
    }

    func testReopenWithinFifteenMinutesSkips() {
        let p = decide(now: "2026-11-20T10:14:59Z", last: "2026-11-20T10:00:00Z", full: "2026-11-20T09:00:00Z")
        XCTAssertFalse(p.run)
    }

    func testExactlyFifteenMinutesRuns() {
        let p = decide(now: "2026-11-20T10:15:00Z", last: "2026-11-20T10:00:00Z", full: "2026-11-20T09:00:00Z")
        XCTAssertTrue(p.run)
        XCTAssertEqual(p.days, 2, "same day: today and yesterday")
        XCTAssertFalse(p.isFull)
    }

    func testNewCalendarDayRunsEvenWithinFifteenMinutes() {
        let p = decide(now: "2026-11-21T00:05:00Z", last: "2026-11-20T23:55:00Z", full: "2026-11-20T10:00:00Z")
        XCTAssertTrue(p.run)
        XCTAssertEqual(p.days, 2)
    }

    func testWindowCoversTheDaysSinceTheLastRun() {
        let p = decide(now: "2026-11-20T10:00:00Z", last: "2026-11-16T09:00:00Z", full: "2026-11-20T08:00:00Z")
        XCTAssertEqual(p.days, 5, "four calendar days back, plus today")
        XCTAssertFalse(p.isFull)
    }

    func testWindowIsCappedAtThirtyDays() {
        let p = decide(now: "2026-11-20T10:00:00Z", last: "2026-09-01T09:00:00Z", full: "2026-11-20T08:00:00Z")
        XCTAssertEqual(p.days, 30)
    }

    func testFullPassDueAfterTwentyFourHours() {
        let p = decide(now: "2026-11-21T10:00:00Z", last: "2026-11-21T09:00:00Z", full: "2026-11-20T09:59:59Z")
        XCTAssertEqual(p, .init(run: true, days: 30, isFull: true))
        let notYet = decide(now: "2026-11-21T09:59:00Z", last: "2026-11-21T09:00:00Z", full: "2026-11-20T10:00:00Z")
        XCTAssertFalse(notYet.isFull)
    }

    func testNoFullPassOnRecordIsFull() {
        let p = decide(now: "2026-11-20T10:00:00Z", last: "2026-11-20T09:00:00Z", full: nil)
        XCTAssertTrue(p.isFull)
    }

    func testClockMovingBackwardsRunsFull() {
        let p = decide(now: "2026-11-20T09:00:00Z", last: "2026-11-20T10:00:00Z", full: "2026-11-20T08:00:00Z")
        XCTAssertEqual(p, .init(run: true, days: 30, isFull: true))
        let futureFull = decide(now: "2026-11-20T11:00:00Z", last: "2026-11-20T10:00:00Z", full: "2026-11-21T08:00:00Z")
        XCTAssertTrue(futureFull.isFull)
    }

    // MARK: state

    func testStateRoundTripAndFullClock() {
        let defaults = UserDefaults(suiteName: "fork.fgsync.tests.\(UUID().uuidString)")!
        let t0 = at("2026-11-20T10:00:00Z")
        let first = HealthForegroundSyncState.plan(repoLoaded: true, now: t0, defaults: defaults)
        XCTAssertTrue(first.isFull)
        HealthForegroundSyncState.recordCompleted(first, now: t0, defaults: defaults)
        let second = HealthForegroundSyncState.plan(repoLoaded: true, now: t0.addingTimeInterval(60), defaults: defaults)
        XCTAssertFalse(second.run, "a completed pass one minute ago")
        let later = HealthForegroundSyncState.plan(repoLoaded: true, now: t0.addingTimeInterval(3600), defaults: defaults)
        XCTAssertTrue(later.run)
        XCTAssertFalse(later.isFull, "the full pass was an hour ago")
        HealthForegroundSyncState.recordCompleted(later, now: t0.addingTimeInterval(3600), defaults: defaults)
        let day = HealthForegroundSyncState.plan(repoLoaded: true, now: t0.addingTimeInterval(25 * 3600), defaults: defaults)
        XCTAssertTrue(day.isFull, "an incremental pass does not extend the 24 h full clock")
    }

    func testAPassThatDidNotCompleteIsRetriedAtTheNextForeground() {
        let defaults = UserDefaults(suiteName: "fork.fgsync.tests.\(UUID().uuidString)")!
        let t0 = at("2026-11-20T10:00:00Z")
        let p = HealthForegroundSyncState.plan(repoLoaded: true, now: t0, defaults: defaults)
        // The bridge was busy and the sync returned false: nothing recorded.
        XCTAssertTrue(HealthForegroundSyncState.plan(repoLoaded: true, now: t0.addingTimeInterval(30), defaults: defaults).run)
        _ = p
    }
}
