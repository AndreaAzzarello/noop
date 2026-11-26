import XCTest
@testable import Strand

final class TodayFeatureStackTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: hour, minute: minute))!
    }

    private func items(detect: Bool = false, include: Bool = true, workout: Bool = false, today: Bool = true,
                       hour: Int = 8, minute: Int = 0) -> [TodayFeatureStack.Item] {
        TodayFeatureStack.items(showsDetection: detect, includesDetection: include, hasWorkoutOnDay: workout,
                                isViewingToday: today, now: date(hour: hour, minute: minute), calendar: calendar)
    }

    func testMorningWithoutWorkoutOpensWithTheFullNightCard() {
        XCTAssertEqual(items(), [.night(.full)])
    }

    func testAWorkoutGoesFirstAndTheNightCardDropsBelowIt() {
        XCTAssertEqual(items(workout: true), [.workout, .night(.full)])
    }

    func testADetectedWorkoutGoesAboveEverything() {
        XCTAssertEqual(items(detect: true, workout: true), [.detected, .workout, .night(.full)])
        XCTAssertEqual(items(detect: true), [.detected, .night(.full)])
    }

    func testTheNightCardTurnsCompactAtNoonSharp() {
        XCTAssertEqual(items(hour: 11, minute: 59), [.night(.full)])
        XCTAssertEqual(items(hour: 12), [.night(.compact)])
        XCTAssertEqual(items(workout: true, hour: 21), [.workout, .night(.compact)])
    }

    func testClassicKeepsItsOwnDetectedCard() {
        XCTAssertEqual(items(detect: true, include: false, workout: true), [.workout, .night(.full)])
    }

    func testPastDaysShowTheirWorkoutButNeverTheNightCard() {
        XCTAssertEqual(items(workout: true, today: false), [.workout])
        XCTAssertEqual(items(workout: false, today: false), [])
        XCTAssertEqual(items(detect: true, workout: true, today: false), [.detected, .workout])
        XCTAssertEqual(items(detect: true, workout: false, today: false), [.detected])
    }

    func testDetectionVisibilityIsOneRule() {
        XCTAssertTrue(TodayFeatureStack.showsDetection(enabled: true, handledThisSession: false, hasCandidate: true))
        XCTAssertFalse(TodayFeatureStack.showsDetection(enabled: false, handledThisSession: false, hasCandidate: true))
        XCTAssertFalse(TodayFeatureStack.showsDetection(enabled: true, handledThisSession: true, hasCandidate: true))
        XCTAssertFalse(TodayFeatureStack.showsDetection(enabled: true, handledThisSession: false, hasCandidate: false))
    }
}
