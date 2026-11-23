import XCTest
@testable import Strand

final class WidgetReloadThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_763_800_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func reload(live: Bool = true, from: Int? = 60, to: Int? = 60, last: Date?, now: Date) -> Bool {
        WidgetReloadThrottle.shouldReload(onlyLiveFieldsChanged: live, previousBattery: from, nextBattery: to,
                                          lastReload: last, now: now)
    }

    func testAnyOtherChangeReloadsAtOnce() {
        XCTAssertTrue(reload(live: false, last: t0, now: at(1)))
    }

    func testLiveOnlyChangeWaitsForTheInterval() {
        XCTAssertFalse(reload(last: t0, now: at(1)))
        XCTAssertFalse(reload(last: t0, now: at(29.9)))
        XCTAssertTrue(reload(last: t0, now: at(30)))
    }

    func testFirstReloadAndAClockThatMovedBackReload() {
        XCTAssertTrue(reload(last: nil, now: t0))
        XCTAssertTrue(reload(last: at(10), now: t0))
    }

    func testLowBatteryCrossingReloadsAtOnceInBothDirections() {
        let line = WidgetReloadThrottle.lowBatteryThreshold
        XCTAssertTrue(reload(from: line + 1, to: line, last: t0, now: at(1)))      // drops onto the line
        XCTAssertTrue(reload(from: line, to: line + 1, last: t0, now: at(1)))      // recovers above it
        XCTAssertFalse(reload(from: line - 3, to: line - 4, last: t0, now: at(1))) // stays low: waits
        XCTAssertFalse(reload(from: line + 5, to: line + 4, last: t0, now: at(1))) // stays fine: waits
    }

    func testUnknownBatteryIsNotACrossing() {
        XCTAssertFalse(WidgetReloadThrottle.crossesLowBattery(previous: nil, next: 10))
        XCTAssertFalse(WidgetReloadThrottle.crossesLowBattery(previous: 10, next: nil))
    }

    /// A day of one reading a minute: at most 2 reloads an hour from the live fields.
    func testADayOfLiveChangesStaysUnderTheBudget() {
        var last: Date?
        var reloads = 0
        for minute in 0..<(24 * 60) {
            let now = at(Double(minute))
            if reload(last: last, now: now) { reloads += 1; last = now }
        }
        XCTAssertLessThanOrEqual(reloads, 48 + 1)
    }

    // MARK: Background policy

    private func background(first: Bool = false, from: Int? = 60, to: Int? = 60, bonded: Bool = false,
                            charge: Bool = false, day: Bool = false) -> Bool {
        WidgetReloadThrottle.backgroundReloadWarranted(firstPublish: first, previousBattery: from, nextBattery: to,
                                                       bondedChanged: bonded, chargeChanged: charge, dayRolled: day)
    }

    func testBackgroundChangesThatAreOnlyLiveOrGradualDoNotReload() {
        XCTAssertFalse(background(), "heart rate, Effort, stress and HRV changes alone")
        XCTAssertFalse(background(from: 60, to: 59))
        XCTAssertFalse(background(from: 10, to: 9), "still low is not a crossing")
    }

    func testBackgroundReloadsForTheEventsThatMatter() {
        let line = WidgetReloadThrottle.lowBatteryThreshold
        XCTAssertTrue(background(first: true))
        XCTAssertTrue(background(from: line + 1, to: line), "drops onto the low line")
        XCTAssertTrue(background(from: line, to: line + 1), "recovers above it")
        XCTAssertTrue(background(bonded: true))
        XCTAssertTrue(background(charge: true))
        XCTAssertTrue(background(day: true))
    }

    func testBackgroundPolicyIgnoresTheForegroundThrottleClock() {
        // The 30-minute live interval belongs to the foreground path; the background rule has no clock at all.
        XCTAssertFalse(background())
        XCTAssertTrue(reload(live: false, last: t0, now: at(1)), "the foreground rule is unchanged")
        XCTAssertFalse(reload(last: t0, now: at(1)))
    }
}
