import XCTest
@testable import Strand

/// The informational warning: does "Night only" HRV capture end inside a Smart Wake window?
final class SmartWakeStreamWindowCheckTests: XCTestCase {
    private func h(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    func testDefaultNightCoversAnEarlyAlarm() {
        // 22:00–07:00, alarm 06:30 with a 30 min window: 06:00–06:29 are inside.
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(6, 30)], windowMinutes: 30, startMin: h(22), endMin: h(7)))
    }

    func testWindowRunningPastTheEndOfTheNightWarns() {
        // Alarm 07:20, window 06:50–07:19, night ends 07:00.
        XCTAssertTrue(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(7, 20)], windowMinutes: 30, startMin: h(22), endMin: h(7)))
    }

    func testMovingTheEndToCoverTheWindowClearsTheWarning() {
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(7, 20)], windowMinutes: 30, startMin: h(22), endMin: h(7, 45)))
    }

    func testTheMaximumMinuteItselfIsNotRequired() {
        // Night ends exactly at the maximum time: every minute before it is covered.
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(7, 20)], windowMinutes: 30, startMin: h(22), endMin: h(7, 20)))
        // One minute short is not.
        XCTAssertTrue(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(7, 20)], windowMinutes: 30, startMin: h(22), endMin: h(7, 19)))
    }

    func testAnyActiveDayCanTriggerIt() {
        // Monday 06:30 is fine, Saturday 08:00 is not.
        XCTAssertTrue(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(6, 30), h(8)], windowMinutes: 30, startMin: h(22), endMin: h(7)))
    }

    func testNoActiveDaysNeverWarns() {
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [], windowMinutes: 30, startMin: h(22), endMin: h(7)))
    }

    func testZeroWindowNeverWarns() {
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(9)], windowMinutes: 0, startMin: h(22), endMin: h(7)))
    }

    func testAlarmJustAfterMidnightUsesTheWrappedWindow() {
        // Alarm 00:10, window 23:40–00:09: inside 22:00–07:00 across midnight.
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(0, 10)], windowMinutes: 30, startMin: h(22), endMin: h(7)))
        // A night starting at 23:50 misses the first minutes of that window.
        XCTAssertTrue(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(0, 10)], windowMinutes: 30, startMin: h(23, 50), endMin: h(7)))
    }

    func testDaytimeWindowWithoutWrap() {
        // A non-wrapping 13:00–15:00 "night" (shift worker) and a 14:30 alarm.
        XCTAssertFalse(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(14, 30)], windowMinutes: 30, startMin: h(13), endMin: h(15)))
        XCTAssertTrue(SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: [h(15, 10)], windowMinutes: 30, startMin: h(13), endMin: h(15)))
    }
}
