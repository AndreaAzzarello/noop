import XCTest
@testable import Strand

final class InsistentWakeAlarmTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Ticks once per second from `from` to `to` (inclusive) and returns what was sent, with the second.
    private func run(_ alarm: inout InsistentWakeAlarm, from: Int, to: Int) -> [(Int, InsistentWakeAlarm.Action)] {
        var result: [(Int, InsistentWakeAlarm.Action)] = []
        for second in from...to {
            for action in alarm.tick(now: at(Double(second))) { result.append((second, action)) }
        }
        return result
    }

    // MARK: The documented sequence

    func testVibratesWaitsFiveMinutesAndVibratesAgain() {
        var alarm = InsistentWakeAlarm()
        var sent: [(Int, InsistentWakeAlarm.Action)] = []
        for action in alarm.start(at: at(0)) { sent.append((0, action)) }
        sent += run(&alarm, from: 1, to: 400)

        // First burst: three commands 5 s apart, at 0, 5 and 10 s.
        XCTAssertEqual(sent.prefix(3).map { $0.0 }, [0, 5, 10])
        XCTAssertEqual(sent.prefix(3).map { $0.1 }, [
            .sendBuzz(burst: 0, index: 0), .sendBuzz(burst: 0, index: 1), .sendBuzz(burst: 0, index: 2)
        ])
        // Nothing in the five minutes after the burst ended (10 s), the second burst begins at 310 s.
        XCTAssertEqual(sent.dropFirst(3).first?.0, 310)
        XCTAssertEqual(sent.dropFirst(3).first?.1, .sendBuzz(burst: 1, index: 0))
        XCTAssertEqual(sent.dropFirst(3).prefix(3).map { $0.0 }, [310, 315, 320])
    }

    func testDoubleTapDuringABurstStopsImmediatelyWithNoFurtherCommands() {
        var alarm = InsistentWakeAlarm()
        _ = alarm.start(at: at(0))
        _ = alarm.tick(now: at(5))

        let result = alarm.doubleTap()
        XCTAssertTrue(result.consumed)
        XCTAssertEqual(result.actions, [.stopped(.doubleTap)])
        XCTAssertEqual(alarm.phase, .stopped(.doubleTap))
        XCTAssertTrue(run(&alarm, from: 6, to: 2_000).isEmpty)
    }

    func testDoubleTapWhileWaitingStopsTheRepeats() {
        var alarm = InsistentWakeAlarm()
        _ = alarm.start(at: at(0))
        _ = run(&alarm, from: 1, to: 100)

        XCTAssertTrue(alarm.doubleTap().consumed)
        XCTAssertTrue(run(&alarm, from: 101, to: 3_000).isEmpty)
    }

    func testStopsAfterTheRepeatLimit() {
        var alarm = InsistentWakeAlarm()
        var sent = alarm.start(at: at(0)).map { (0, $0) }
        sent += run(&alarm, from: 1, to: 6_000)

        let buzzes = sent.compactMap { _, action -> (Int, Int)? in
            if case let .sendBuzz(burst, index) = action { return (burst, index) }
            return nil
        }
        // 1 first burst + 6 repeats, 3 commands each.
        XCTAssertEqual(buzzes.count, 7 * 3)
        XCTAssertEqual(buzzes.last?.0, 6)
        XCTAssertEqual(sent.last?.1, .stopped(.repeatLimit))
        XCTAssertEqual(alarm.phase, .stopped(.repeatLimit))
        XCTAssertFalse(alarm.isActive)
        // The limit is reached on the third command of the seventh burst: 6 waits of 300 s plus 6 bursts of 10 s.
        XCTAssertEqual(sent.last?.0, 6 * 300 + 6 * 10 + 10)
    }

    // MARK: Robustness

    func testDuplicateTicksDoNotDuplicateCommands() {
        var alarm = InsistentWakeAlarm()
        XCTAssertEqual(alarm.start(at: at(0)), [.sendBuzz(burst: 0, index: 0)])
        XCTAssertTrue(alarm.tick(now: at(0)).isEmpty)
        XCTAssertTrue(alarm.tick(now: at(2)).isEmpty)
        XCTAssertEqual(alarm.tick(now: at(5)), [.sendBuzz(burst: 0, index: 1)])
        XCTAssertTrue(alarm.tick(now: at(5)).isEmpty)
    }

    func testALongSuspensionSendsOneBurstNotTheMissedOnes() {
        var alarm = InsistentWakeAlarm()
        _ = alarm.start(at: at(0))
        _ = run(&alarm, from: 1, to: 10)

        // The process is suspended for 20 minutes; three bursts' worth of time passes.
        var sent: [(Int, InsistentWakeAlarm.Action)] = []
        for action in alarm.tick(now: at(1_210)) { sent.append((1_210, action)) }
        sent += run(&alarm, from: 1_211, to: 1_230)
        XCTAssertEqual(sent.map { $0.0 }, [1_210, 1_215, 1_220])
        XCTAssertEqual(sent.first?.1, .sendBuzz(burst: 1, index: 0))
        // The next burst is a full wait later, not immediately.
        XCTAssertTrue(run(&alarm, from: 1_231, to: 1_500).isEmpty)
    }

    func testStartingTwiceIsIgnored() {
        var alarm = InsistentWakeAlarm()
        XCTAssertFalse(alarm.start(at: at(0)).isEmpty)
        XCTAssertTrue(alarm.start(at: at(30)).isEmpty)
        _ = alarm.doubleTap()
        XCTAssertTrue(alarm.start(at: at(60)).isEmpty, "a finished morning is not restarted")
    }

    func testADoubleTapWithNothingRunningIsNotConsumed() {
        var idle = InsistentWakeAlarm()
        XCTAssertFalse(idle.doubleTap().consumed)

        var done = InsistentWakeAlarm()
        _ = done.start(at: at(0))
        _ = done.doubleTap()
        let again = done.doubleTap()
        XCTAssertFalse(again.consumed)
        XCTAssertTrue(again.actions.isEmpty)
    }

    func testTickBeforeStartDoesNothing() {
        var alarm = InsistentWakeAlarm()
        XCTAssertTrue(alarm.tick(now: at(100)).isEmpty)
    }

    // MARK: Single burst

    func testSingleBurstModeStopsAfterOneBurst() {
        var alarm = InsistentWakeAlarm(configuration: .single)
        var sent = alarm.start(at: at(0)).map { (0, $0) }
        sent += run(&alarm, from: 1, to: 2_000)

        XCTAssertEqual(sent.count, 4)   // 3 commands and the stop
        XCTAssertEqual(sent.last?.1, .stopped(.singleBurstDone))
        XCTAssertEqual(sent.last?.0, 10)
        XCTAssertEqual(alarm.phase, .stopped(.singleBurstDone))
        XCTAssertFalse(alarm.doubleTap().consumed, "after the burst the tap is not this type's to consume")
    }

    func testConfigurationDefaultsMatchTheDocumentedBehaviour() {
        let configuration = InsistentWakeAlarm.Configuration.insistent
        XCTAssertEqual(configuration.repeatInterval, 300)
        XCTAssertEqual(configuration.maximumRepeats, 6)
        XCTAssertEqual(configuration.commandsPerBurst, 3)
        XCTAssertTrue(configuration.repeats)
        XCTAssertFalse(InsistentWakeAlarm.Configuration.single.repeats)
    }
}
