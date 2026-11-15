import XCTest

final class SmartWakeFallbackReconcilerTests: XCTestCase {
    private let everyDay = Set(1...7)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func allEmpty() -> [Int: Set<Int>] {
        Dictionary(uniqueKeysWithValues: (1...7).map { ($0, Set<Int>()) })
    }

    func testEmptyListRepeatedWithinDebounceRearmsOnlyOnce() {
        var reconciler = SmartWakeFallbackReconciler()
        var rearms = 0
        for i in 0..<10 {
            let actions = reconciler.decide(
                occupied: allEmpty(),
                selectedDays: [3],
                activeSlots: [:],
                now: t0.addingTimeInterval(Double(i) * 5)
            )
            rearms += actions.filter { $0 == .rearm(weekday: 3) }.count
        }
        XCTAssertEqual(rearms, 1)
    }

    func testRearmIsAllowedAgainAfterTheDebounce() {
        var reconciler = SmartWakeFallbackReconciler()
        let first = reconciler.decide(occupied: allEmpty(), selectedDays: [3], activeSlots: [:], now: t0)
        let later = reconciler.decide(
            occupied: allEmpty(), selectedDays: [3], activeSlots: [:],
            now: t0.addingTimeInterval(SmartWakeFallbackReconciler.rearmDebounce)
        )
        XCTAssertEqual(first, [.rearm(weekday: 3)])
        XCTAssertEqual(later, [.rearm(weekday: 3)])
    }

    func testDebounceIsPerWeekday() {
        var reconciler = SmartWakeFallbackReconciler()
        _ = reconciler.decide(occupied: allEmpty(), selectedDays: [3], activeSlots: [:], now: t0)
        let other = reconciler.decide(occupied: allEmpty(), selectedDays: [3, 4], activeSlots: [:], now: t0.addingTimeInterval(1))
        XCTAssertEqual(other, [.rearm(weekday: 4)])
    }

    func testRecordedSlotMatchingTheArmedOneDoesNothing() {
        var reconciler = SmartWakeFallbackReconciler()
        var occupied = allEmpty()
        occupied[2] = [1]
        let actions = reconciler.decide(occupied: occupied, selectedDays: [2], activeSlots: [2: 1], now: t0)
        XCTAssertEqual(actions, [])
    }

    func testMissingRecordMeansSlotZero() {
        var reconciler = SmartWakeFallbackReconciler()
        var occupied = allEmpty()
        occupied[2] = [0]
        XCTAssertEqual(reconciler.decide(occupied: occupied, selectedDays: [2], activeSlots: [:], now: t0), [])
    }

    func testArmedSlotDifferentFromRecordedIsAdoptedOnce() {
        var reconciler = SmartWakeFallbackReconciler()
        var occupied = allEmpty()
        occupied[2] = [1]
        let actions = reconciler.decide(occupied: occupied, selectedDays: [2], activeSlots: [2: 0], now: t0)
        XCTAssertEqual(actions, [.adoptSlot(weekday: 2, slot: 1)])
    }

    func testBothSlotsArmedRemovesTheOneNotRecordedAsLive() {
        var reconciler = SmartWakeFallbackReconciler()
        var occupied = allEmpty()
        occupied[5] = [0, 1]
        XCTAssertEqual(
            reconciler.decide(occupied: occupied, selectedDays: [5], activeSlots: [5: 1], now: t0),
            [.cancelIdle(weekday: 5, slot: 0)]
        )
        XCTAssertEqual(
            reconciler.decide(occupied: occupied, selectedDays: [5], activeSlots: [:], now: t0),
            [.cancelIdle(weekday: 5, slot: 1)]
        )
    }

    func testDeselectedDayIsClearedAndNeverRearmed() {
        var reconciler = SmartWakeFallbackReconciler()
        var occupied = allEmpty()
        occupied[6] = [0, 1]
        let actions = reconciler.decide(occupied: occupied, selectedDays: [2], activeSlots: [:], now: t0)
        XCTAssertTrue(actions.contains(.cancelDeselected(weekday: 6, slots: [0, 1])))
        XCTAssertFalse(actions.contains(.rearm(weekday: 6)))
    }

    func testEverySelectedDayWithNothingArmedIsRearmed() {
        var reconciler = SmartWakeFallbackReconciler()
        let actions = reconciler.decide(occupied: allEmpty(), selectedDays: everyDay, activeSlots: [:], now: t0)
        XCTAssertEqual(actions, (1...7).map { SmartWakeFallbackReconciler.Action.rearm(weekday: $0) })
    }

    func testLogThrottleAllowsOneLinePerEventPerWeekdayPerDay() {
        var throttle = SmartWakeLogThrottle()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(throttle.shouldLog("rearm", weekday: 3, now: day1, calendar: calendar))
        XCTAssertFalse(throttle.shouldLog("rearm", weekday: 3, now: day1.addingTimeInterval(60), calendar: calendar))
        XCTAssertTrue(throttle.shouldLog("rearm", weekday: 4, now: day1, calendar: calendar))
        XCTAssertTrue(throttle.shouldLog("both-slots", weekday: 3, now: day1, calendar: calendar))
        XCTAssertTrue(throttle.shouldLog("rearm", weekday: 3, now: day1.addingTimeInterval(24 * 3600), calendar: calendar))
    }
}
