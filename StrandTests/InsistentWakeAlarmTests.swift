import XCTest
@testable import Strand

final class InsistentWakeAlarmTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Ticks once per second from `from` to `to` (inclusive) and returns what came back, with the second.
    private func run(_ alarm: inout InsistentWakeAlarm, from: Int, to: Int) -> [(Int, InsistentWakeAlarm.Action)] {
        var result: [(Int, InsistentWakeAlarm.Action)] = []
        for second in from...to {
            for action in alarm.tick(now: at(Double(second))) { result.append((second, action)) }
        }
        return result
    }

    // MARK: Never a haptic command

    func testStartOnlyAsksToArmTheFirmwareAlarmOnce() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        let actions = alarm.start(at: at(0))
        XCTAssertEqual(actions, [.armFirmware(at: at(30), attempt: 0)])
        XCTAssertEqual(alarm.phase, .armed(fireAt: at(30), attempt: 0))
        // Nothing else is due until the armed instant has passed.
        XCTAssertTrue(run(&alarm, from: 1, to: 119).isEmpty)
    }

    func testSecondStartIsIgnored() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        _ = alarm.start(at: at(0))
        XCTAssertTrue(alarm.start(at: at(10)).isEmpty)
        XCTAssertEqual(alarm.phase, .armed(fireAt: at(30), attempt: 0))
    }

    func testStartAtAnAlreadyArmedInstantSendsNothing() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        XCTAssertTrue(alarm.start(at: at(0), firstFireAt: at(5)).isEmpty)
        XCTAssertEqual(alarm.phase, .armed(fireAt: at(5), attempt: 0))
    }

    // MARK: armed -> fired

    func testFirmwareEventMovesArmedToFired() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        _ = alarm.start(at: at(0))
        XCTAssertTrue(alarm.firmwareFired(now: at(31)))
        XCTAssertEqual(alarm.phase, .fired(at: at(31), attempt: 0))
        XCTAssertTrue(alarm.isActive)
    }

    func testFirmwareEventIsNotConsumedWhenIdleOrStopped() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        XCTAssertFalse(alarm.firmwareFired(now: at(0)))
        _ = alarm.start(at: at(0))
        _ = alarm.doubleTap()
        XCTAssertFalse(alarm.firmwareFired(now: at(40)))
    }

    func testMissingFirmwareEventIsReportedOnceAndTheRunGoesOn() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        _ = alarm.start(at: at(0))
        let seen = run(&alarm, from: 1, to: 125)
        // fireAt 30 + 90 s grace = 120.
        XCTAssertEqual(seen.map { $0.0 }, [120])
        XCTAssertEqual(seen.first?.1, .firedNotObserved(attempt: 0))
        XCTAssertEqual(alarm.phase, .fired(at: at(120), attempt: 0))
    }

    // MARK: Single vibration

    func testSingleRunExpiresFiveMinutesAfterTheFire() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        _ = alarm.start(at: at(0))
        _ = alarm.firmwareFired(now: at(30))
        XCTAssertTrue(run(&alarm, from: 31, to: 329).isEmpty)
        XCTAssertEqual(run(&alarm, from: 330, to: 330).first?.1, .stopped(.expired))
        XCTAssertEqual(alarm.phase, .stopped(.expired))
        XCTAssertTrue(run(&alarm, from: 331, to: 5_000).isEmpty)
    }

    // MARK: Insistent repeats

    func testInsistentRepeatsFiveMinutesAfterAFireWithoutATap() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        _ = alarm.start(at: at(0))
        _ = alarm.firmwareFired(now: at(30))
        let seen = run(&alarm, from: 31, to: 400)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].0, 330)
        XCTAssertEqual(seen[0].1, .armFirmware(at: at(360), attempt: 1))
        XCTAssertEqual(alarm.phase, .armed(fireAt: at(360), attempt: 1))
    }

    func testRunsExactlySixRepeatsThenStopsAtTheLimit() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        var armed = alarm.start(at: at(0)).count
        var now = 0
        var stoppedAt: Int?
        // Every arm is answered by an event 57 right at its instant.
        while stoppedAt == nil, now < 20_000 {
            now += 1
            if case let .armed(fireAt, _) = alarm.phase, at(Double(now)) >= fireAt { _ = alarm.firmwareFired(now: at(Double(now))) }
            for action in alarm.tick(now: at(Double(now))) {
                switch action {
                case .armFirmware: armed += 1
                case .stopped(.repeatLimit): stoppedAt = now
                default: XCTFail("unexpected \(action)")
                }
            }
        }
        XCTAssertEqual(armed, 7, "the first arm plus six repeats")
        XCTAssertNotNil(stoppedAt)
        XCTAssertEqual(alarm.phase, .stopped(.repeatLimit))
    }

    // MARK: Double tap

    func testDoubleTapWhileArmedStops() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        _ = alarm.start(at: at(0))
        let result = alarm.doubleTap()
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(result.actions, [.stopped(.doubleTap)])
        XCTAssertTrue(run(&alarm, from: 1, to: 5_000).isEmpty)
    }

    func testDoubleTapWhileVibratingStopsTheRepeats() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        _ = alarm.start(at: at(0))
        _ = alarm.firmwareFired(now: at(30))
        _ = run(&alarm, from: 31, to: 100)
        XCTAssertTrue(alarm.doubleTap().consumed)
        XCTAssertEqual(alarm.phase, .stopped(.doubleTap))
        XCTAssertTrue(run(&alarm, from: 101, to: 5_000).isEmpty)
    }

    func testDoubleTapIsNotConsumedWhenIdleOrAfterTheRunEnded() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        XCTAssertFalse(alarm.doubleTap().consumed)
        _ = alarm.start(at: at(0))
        _ = alarm.doubleTap()
        let again = alarm.doubleTap()
        XCTAssertFalse(again.consumed)
        XCTAssertTrue(again.actions.isEmpty)
    }

    // MARK: Robustness

    func testALateTickAfterASuspensionReturnsOneActionNotAReplay() {
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        _ = alarm.start(at: at(0))
        _ = alarm.firmwareFired(now: at(30))
        // The app slept for an hour: one re-arm, not twelve.
        XCTAssertEqual(alarm.tick(now: at(3_600)), [.armFirmware(at: at(3_630), attempt: 1)])
        XCTAssertTrue(alarm.tick(now: at(3_600)).isEmpty)
    }

    func testTestConfigurationArmsOneMinuteAheadWithoutRepeats() {
        var alarm = InsistentWakeAlarm(configuration: .test)
        XCTAssertEqual(alarm.start(at: at(0)), [.armFirmware(at: at(60), attempt: 0)])
        _ = alarm.firmwareFired(now: at(60))
        XCTAssertEqual(run(&alarm, from: 61, to: 400).map { $0.1 }, [.stopped(.expired)])
    }

    func testNoRunEverAsksForAnythingButTheFirmwareAlarm() {
        // The whole action vocabulary is arm / not-observed / stopped: there is no haptic action to send.
        var alarm = InsistentWakeAlarm(configuration: .insistent)
        var all = alarm.start(at: at(0))
        for second in 1...20_000 {
            if case let .armed(fireAt, _) = alarm.phase, at(Double(second)) >= fireAt { _ = alarm.firmwareFired(now: at(Double(second))) }
            all += alarm.tick(now: at(Double(second)))
        }
        for action in all {
            switch action {
            case .armFirmware, .firedNotObserved, .stopped: break
            }
        }
        XCTAssertFalse(all.isEmpty)
    }
}
