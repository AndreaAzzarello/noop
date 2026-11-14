import XCTest

final class SmartWakeEngineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEngine(
        baselineBPM: Int = 60,
        baselineCount: Int = 24,
        maximumWakeOffset: TimeInterval = 3_600
    ) -> (SmartWakeEngine, Date, Date) {
        let maximumWake = epoch.addingTimeInterval(maximumWakeOffset)
        let configuration = SmartWakeConfiguration.standard(maximumWakeTime: maximumWake)
        let baseline = (0..<baselineCount).map { index in
            SmartWakeHeartRateSample(
                bpm: baselineBPM,
                timestamp: configuration.windowStart.addingTimeInterval(-Double(baselineCount - index) * 60)
            )
        }
        return (SmartWakeEngine(configuration: configuration, baselineSamples: baseline),
                configuration.windowStart, maximumWake)
    }

    func testStableHeartRateDoesNotTriggerEarlyWake() {
        var (engine, start, maximumWake) = makeEngine()
        for minute in 0..<8 {
            let time = start.addingTimeInterval(Double(minute) * 60)
            XCTAssertEqual(
                engine.ingest(.init(bpm: 61, timestamp: time), at: time),
                .waiting
            )
        }
        XCTAssertEqual(engine.evaluate(at: maximumWake.addingTimeInterval(-1)), .waiting)
    }

    func testOneIsolatedSpikeDoesNotTriggerEarlyWake() {
        var (engine, start, _) = makeEngine()
        let spike = start.addingTimeInterval(60)
        XCTAssertEqual(engine.ingest(.init(bpm: 80, timestamp: spike), at: spike), .waiting)

        let recovery = spike.addingTimeInterval(60)
        XCTAssertEqual(engine.ingest(.init(bpm: 61, timestamp: recovery), at: recovery), .waiting)

        let next = recovery.addingTimeInterval(60)
        XCTAssertEqual(engine.ingest(.init(bpm: 80, timestamp: next), at: next), .waiting)
    }

    func testSustainedRiseTriggersOnlyAfterThreeSamplesAcrossTwoMinutes() {
        var (engine, start, _) = makeEngine()
        for minute in 0..<2 {
            let time = start.addingTimeInterval(Double(minute) * 60)
            XCTAssertEqual(engine.ingest(.init(bpm: 67, timestamp: time), at: time), .waiting)
        }

        let third = start.addingTimeInterval(120)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 68, timestamp: third), at: third),
            .wake(.sustainedHeartRateRise)
        )
        XCTAssertEqual(engine.evaluate(at: third.addingTimeInterval(1)), .alreadyTriggered)
    }

    func testGapBetweenSamplesResetsSustainedRise() {
        var (engine, start, _) = makeEngine()
        let first = start
        let second = start.addingTimeInterval(60)
        let afterGap = start.addingTimeInterval(300)

        XCTAssertEqual(engine.ingest(.init(bpm: 68, timestamp: first), at: first), .waiting)
        XCTAssertEqual(engine.ingest(.init(bpm: 68, timestamp: second), at: second), .waiting)
        XCTAssertEqual(engine.ingest(.init(bpm: 68, timestamp: afterGap), at: afterGap), .waiting)
    }

    func testInsufficientBaselineNeverTriggersEarlyWake() {
        var (engine, start, maximumWake) = makeEngine(baselineCount: 5)
        for minute in 0..<5 {
            let time = start.addingTimeInterval(Double(minute) * 60)
            XCTAssertEqual(engine.ingest(.init(bpm: 90, timestamp: time), at: time), .waiting)
        }
        XCTAssertEqual(engine.evaluate(at: maximumWake), .wake(.maximumWakeTime))
    }

    func testMissingHeartRateStillUsesMaximumWakeFallback() {
        var (engine, _, maximumWake) = makeEngine()
        XCTAssertEqual(engine.evaluate(at: maximumWake.addingTimeInterval(-1)), .waiting)
        XCTAssertEqual(engine.evaluate(at: maximumWake), .wake(.maximumWakeTime))
        XCTAssertEqual(engine.evaluate(at: maximumWake.addingTimeInterval(30)), .alreadyTriggered)
    }

    func testRejectsInvalidStaleAndOutOfOrderSamples() {
        var (engine, start, _) = makeEngine()
        let invalid = start.addingTimeInterval(30)
        XCTAssertEqual(engine.ingest(.init(bpm: 0, timestamp: invalid), at: invalid), .waiting)

        let stale = start.addingTimeInterval(60)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 90, timestamp: stale), at: stale.addingTimeInterval(301)),
            .waiting
        )

        let fresh = start.addingTimeInterval(120)
        XCTAssertEqual(engine.ingest(.init(bpm: 68, timestamp: fresh), at: fresh), .waiting)
        XCTAssertEqual(engine.ingest(.init(bpm: 68, timestamp: fresh), at: fresh), .waiting)
    }

    func testRejectsOutOfOrderSampleAfterNonElevatedSample() {
        var (engine, start, _) = makeEngine()
        let firstStable = start.addingTimeInterval(60)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 61, timestamp: firstStable), at: firstStable),
            .waiting
        )

        // This timestamp is older than the last valid sample, but there is no
        // elevated sample yet. It must not seed a false sustained-rise sequence.
        let outOfOrder = start.addingTimeInterval(30)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 68, timestamp: outOfOrder), at: firstStable),
            .waiting
        )

        let secondElevated = start.addingTimeInterval(90)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 68, timestamp: secondElevated), at: secondElevated),
            .waiting
        )
        let thirdElevated = start.addingTimeInterval(150)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 68, timestamp: thirdElevated), at: thirdElevated),
            .waiting
        )
    }

    // MARK: 1 Hz streams (the real 0x2A37 cadence). Baseline is 60 bpm, so >= 66 is elevated.

    /// Feeds one sample per second at `start + second` and returns the first second that woke.
    private func firstWakeSecond(
        _ engine: inout SmartWakeEngine,
        start: Date,
        seconds: [Int],
        bpm: (Int) -> Int
    ) -> Int? {
        for second in seconds {
            let time = start.addingTimeInterval(Double(second))
            if engine.ingest(.init(bpm: bpm(second), timestamp: time), at: time) == .wake(.sustainedHeartRateRise) {
                return second
            }
        }
        return nil
    }

    func testOneHertzSustainedRiseTriggersAfterTwoMinutes() {
        var (engine, start, _) = makeEngine()
        let wake = firstWakeSecond(&engine, start: start, seconds: Array(0...150)) { _ in 70 }
        XCTAssertEqual(wake, 120)
    }

    func testOneHertzRiseWithIsolatedDipsStillTriggers() {
        var (engine, start, _) = makeEngine()
        // One calm sample every ten seconds: ~10% of the window, under the 20% tolerance.
        let wake = firstWakeSecond(&engine, start: start, seconds: Array(0...150)) { $0 % 10 == 5 ? 60 : 70 }
        XCTAssertNotNil(wake)
        XCTAssertLessThanOrEqual(wake ?? .max, 130)
    }

    func testOneHertzProlongedDipDoesNotTrigger() {
        var (engine, start, _) = makeEngine()
        // Elevated for 60 s, calm for 50 s, elevated again: the window never reaches 80%.
        let wake = firstWakeSecond(&engine, start: start, seconds: Array(0...170)) {
            (60..<110).contains($0) ? 60 : 70
        }
        XCTAssertNil(wake)
    }

    func testGapBeyondMaximumSampleGapRestartsTheTwoMinuteClock() {
        var (engine, start, _) = makeEngine()
        let first = Array(0...100)
        let afterGap = Array(300...450)
        let wake = firstWakeSecond(&engine, start: start, seconds: first + afterGap) { _ in 70 }
        // The 100 s before the 200 s hole do not count: the new series needs its own 120 s.
        XCTAssertEqual(wake, 420)
    }

    func testSamplesOutsideWakeWindowCannotTriggerEarlyWake() {
        var (engine, start, _) = makeEngine()
        let beforeWindow = start.addingTimeInterval(-1)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 90, timestamp: beforeWindow), at: start),
            .waiting
        )
    }
}
