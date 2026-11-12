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

    func testSamplesOutsideWakeWindowCannotTriggerEarlyWake() {
        var (engine, start, _) = makeEngine()
        let beforeWindow = start.addingTimeInterval(-1)
        XCTAssertEqual(
            engine.ingest(.init(bpm: 90, timestamp: beforeWindow), at: start),
            .waiting
        )
    }
}
