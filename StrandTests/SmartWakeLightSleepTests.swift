import XCTest

/// The light-sleep rule's gating (reference, window, holes, streak), its scoring pieces and the respiration
/// feature. The numeric calibration of the wake threshold is NOT covered here: it needs recorded nights and is
/// checked by `Tools/SmartWakeReplay`.
final class SmartWakeLightSleepTests: XCTestCase {
    /// A multiple of 30 s, so epochs line up with the test timeline.
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// Window 30 min long, ending 3600 s after `epoch`: it starts at +1800 s.
    ///
    /// The gating tests below are about epochs, holes and reference length, so they use the plain rule (3 epochs,
    /// no transition requirement); the transition requirement has its own tests.
    private func makeDetector(
        threshold: Double = 0,
        window: TimeInterval = 30 * 60,
        requiredEpochs: Int = 3,
        transitionLookback: Int = 0
    ) -> SmartWakeLightSleepDetector {
        var configuration = SmartWakeLightSleepDetector.Configuration.standard
        configuration.lightProbabilityThreshold = threshold
        configuration.requiredConsecutiveEpochs = requiredEpochs
        configuration.transitionLookbackEpochs = transitionLookback
        return SmartWakeLightSleepDetector(
            maximumWakeTime: epoch.addingTimeInterval(3_600),
            windowDuration: window,
            configuration: configuration
        )
    }

    /// One sample per second (a small repeating wobble around 60 bpm) for the seconds in `range`, minus those
    /// `skip` rejects. Returns the time of the first sample that made the detector report a wake.
    private func feed(
        _ detector: inout SmartWakeLightSleepDetector,
        _ range: Range<Int>,
        skip: (Int) -> Bool = { _ in false }
    ) -> Date? {
        for second in range where !skip(second) {
            let time = epoch.addingTimeInterval(Double(second))
            if detector.ingest(bpm: 60 + (second % 7) - 3, at: time) { return time }
        }
        return nil
    }

    // MARK: Gating

    func testWakesAfterThreeConsecutiveValidWindowEpochs() {
        var detector = makeDetector()
        // 40 min of reference, then the window. Window epoch 0 closes at +1830, epoch 2 at +1890.
        let fired = feed(&detector, -600..<2_100)
        XCTAssertEqual(fired, epoch.addingTimeInterval(1_800 + 90))
        XCTAssertEqual(detector.diagnostics.firedAt, epoch.addingTimeInterval(1_890))
        XCTAssertGreaterThanOrEqual(detector.diagnostics.referenceEpochs, 60)
    }

    func testReportsTheWakeOnlyOnce() {
        var detector = makeDetector()
        XCTAssertNotNil(feed(&detector, -600..<2_100))
        XCTAssertNil(feed(&detector, 2_100..<3_000))
    }

    func testShortReferenceNeverWakesEarly() {
        var detector = makeDetector()
        // Only 10 minutes before the window: fewer than the 60 reference epochs, however good the window is.
        XCTAssertNil(feed(&detector, 1_200..<3_500))
        XCTAssertLessThan(detector.diagnostics.referenceEpochs, 60)
        XCTAssertTrue(detector.summary.contains("fired=none (reference too short)"), detector.summary)
    }

    func testEpochsWithTooFewSamplesAreNotUsable() {
        var detector = makeDetector()
        // Every other second missing inside the window: 15 samples per epoch, under the 20 required.
        XCTAssertNil(feed(&detector, -600..<3_500, skip: { $0 >= 1_800 && $0 % 2 == 1 }))
        XCTAssertGreaterThanOrEqual(detector.diagnostics.invalidEpochs, 3)
        XCTAssertEqual(detector.diagnostics.windowEpochs, 0)
    }

    func testAHoleInsideAnEpochMakesItUnusable() {
        var detector = makeDetector()
        // A 12 s hole in the middle of every window epoch: 18 samples and a gap above the 10 s allowed.
        XCTAssertNil(feed(&detector, -600..<3_500, skip: { $0 >= 1_800 && ($0 % 30) >= 9 && ($0 % 30) < 21 }))
        XCTAssertEqual(detector.diagnostics.windowEpochs, 0)
    }

    func testAMissingEpochRestartsTheStreak() {
        var detector = makeDetector()
        // Window epochs 0 and 1 are fine, epoch 2 has no samples, epochs 3, 4, 5 are fine. Without the restart the
        // rule would complete at epoch 3 (closing at +1920); with it, at epoch 5 (closing at +1980).
        let fired = feed(&detector, -600..<2_100, skip: { $0 >= 1_860 && $0 < 1_890 })
        XCTAssertEqual(fired, epoch.addingTimeInterval(1_800 + 180))
    }

    func testThresholdAboveOneNeverFires() {
        var detector = makeDetector(threshold: 1.1)
        XCTAssertNil(feed(&detector, -600..<3_500))
        XCTAssertGreaterThan(detector.diagnostics.windowEpochs, 10)
        XCTAssertLessThanOrEqual(detector.diagnostics.maximumLightProbability, 1.0 + 1e-9)
        XCTAssertTrue(detector.summary.contains("fired=none (never light)"), detector.summary)
    }

    // MARK: Transition into light

    func testShippedRuleNeedsFourEpochsAndATransition() {
        let configuration = SmartWakeLightSleepDetector.Configuration.standard
        XCTAssertEqual(configuration.lightProbabilityThreshold, 0.60)
        XCTAssertEqual(configuration.requiredConsecutiveEpochs, 4)
        XCTAssertEqual(configuration.transitionLookbackEpochs, 10)
    }

    func testRequiresFourEpochsWhenConfiguredSo() {
        var detector = makeDetector(requiredEpochs: 4)
        // Window epoch 0 closes at +1830, epoch 3 at +1920.
        XCTAssertEqual(feed(&detector, -600..<2_100), epoch.addingTimeInterval(1_800 + 120))
    }

    func testALightRunFromTheStartOfTheWindowIsNotAnEntry() {
        // fork: the run opens the window with nothing contiguous before it (a hole of 90 s), so there is no earlier
        // epoch to have been REM or deep: the transition requirement keeps the rule silent.
        var detector = makeDetector(requiredEpochs: 4, transitionLookback: 10)
        XCTAssertNil(feed(&detector, -600..<3_500, skip: { $0 >= 1_710 && $0 < 1_800 }))
        XCTAssertGreaterThan(detector.diagnostics.blockedWithoutTransition, 0)
        XCTAssertTrue(detector.summary.contains("fired=none (no transition into light)"), detector.summary)
    }

    // fork: epochs just before the window count toward an entry, only when contiguous and recent.

    func testRemRightBeforeTheWindowCountsAsAnEntryForARunThatOpensIt() {
        // The synthetic signal is scored REM, so the epochs just before the window are REM: the run that opens the
        // window follows REM and the rule may fire.
        var detector = makeDetector(requiredEpochs: 4, transitionLookback: 10)
        XCTAssertNotNil(feed(&detector, -600..<2_100))
        XCTAssertEqual(detector.diagnostics.blockedWithoutTransition, 0)
        XCTAssertTrue(detector.summary.contains("epochs="), detector.summary)
    }

    func testAHoleBeforeTheWindowLeavesNoEntry() {
        // 90 s without samples right before the window: no epoch touches the window start, so the earlier REM is
        // too old to count and nothing may fire from a run that opens the window.
        var detector = makeDetector(requiredEpochs: 4, transitionLookback: 10)
        XCTAssertNil(feed(&detector, -600..<1_800, skip: { $0 >= 1_710 }))
        XCTAssertNil(feed(&detector, 1_800..<3_500))
        XCTAssertGreaterThan(detector.diagnostics.blockedWithoutTransition, 0)
    }

    func testAnUnusableEpochBeforeTheWindowLeavesNoEntry() {
        // Sparse samples in the last 4 epochs before the window: they are unusable, so no evidence is kept.
        var detector = makeDetector(requiredEpochs: 4, transitionLookback: 10)
        XCTAssertNil(feed(&detector, -600..<1_800, skip: { $0 >= 1_680 && $0 % 2 == 1 }))
        XCTAssertNil(feed(&detector, 1_800..<3_500))
        XCTAssertGreaterThan(detector.diagnostics.blockedWithoutTransition, 0)
    }

    func testPreWindowStagesNeedTwoRemOrDeepEpochs() {
        typealias Stage = SmartWakeLightSleepDetector.Stage
        let run: [Stage?] = [.light, .light, .light, .light]
        XCTAssertTrue(SmartWakeLightSleepDetector.enteredLight(stages: run, run: 4, lookback: 10, before: [.light, .rem, .rem]))
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: run, run: 4, lookback: 10, before: [.light, .light, .rem]))
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: run, run: 4, lookback: 10, before: []))
        // Only the epochs the lookback still reaches count: the run starts at 0, lookback 3 reaches 3 epochs back.
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(
            stages: run, run: 4, lookback: 3, before: [.rem, .rem, .light, .light, .light]))
        // A run that starts later in the window is judged by the window alone, as before.
        XCTAssertTrue(SmartWakeLightSleepDetector.enteredLight(
            stages: [.rem, .light, .light, .light, .light], run: 4, lookback: 10, before: []))
    }

    func testLightRunsAtTheStartWithoutRemStayBlocked() {
        typealias Stage = SmartWakeLightSleepDetector.Stage
        let stages: [Stage?] = Array(repeating: .light, count: 17) + Array(repeating: .rem, count: 42)
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: Array(stages.prefix(17)), run: 17, lookback: 10))
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(
            stages: Array(stages.prefix(17)), run: 17, lookback: 10, before: [.light, .light]))
    }

    func testDisablingTheTransitionRestoresThePlainRule() {
        var detector = makeDetector(requiredEpochs: 4, transitionLookback: 0)
        XCTAssertNotNil(feed(&detector, -600..<2_100))
        XCTAssertEqual(detector.diagnostics.blockedWithoutTransition, 0)
    }

    func testTransitionLookbackWindow() {
        typealias Stage = SmartWakeLightSleepDetector.Stage
        let light: Stage? = .light
        // Four light epochs after a REM epoch that is 3 epochs before the run.
        let stages: [Stage?] = [.light, .rem, .light, .light, light, light, light, light]
        XCTAssertTrue(SmartWakeLightSleepDetector.enteredLight(stages: stages, run: 4, lookback: 10))
        // The same REM epoch is outside a lookback of 2 epochs.
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: stages, run: 4, lookback: 2))
        // Deep counts like REM.
        XCTAssertTrue(SmartWakeLightSleepDetector.enteredLight(stages: [.deep, .light, .light, .light, .light], run: 4, lookback: 10))
        // Awake and unusable epochs are not an entry; neither is a run with nothing before it.
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: [.awake, nil, .light, .light, .light, .light], run: 4, lookback: 10))
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: [.light, .light, .light, .light], run: 4, lookback: 10))
        XCTAssertFalse(SmartWakeLightSleepDetector.enteredLight(stages: [], run: 0, lookback: 10))
        // Lookback 0 switches the requirement off.
        XCTAssertTrue(SmartWakeLightSleepDetector.enteredLight(stages: [.light, .light, .light, .light], run: 4, lookback: 0))
    }

    func testNothingBeforeTheWindowOrAfterTheMaximumTime() {
        var detector = makeDetector()
        XCTAssertNil(feed(&detector, -600..<1_800))
        XCTAssertEqual(detector.diagnostics.windowEpochs, 0)

        var late = makeDetector()
        // Reference, then silence through the window, then samples after the maximum time.
        XCTAssertNil(feed(&late, -600..<1_800))
        XCTAssertNil(feed(&late, 3_600..<3_800))
        XCTAssertEqual(late.diagnostics.windowEpochs, 0)
    }

    func testOutOfOrderAndInvalidSamplesAreIgnored() {
        var detector = makeDetector()
        XCTAssertFalse(detector.ingest(bpm: 60, at: epoch))
        XCTAssertFalse(detector.ingest(bpm: 60, at: epoch.addingTimeInterval(-5)))
        XCTAssertFalse(detector.ingest(bpm: 250, at: epoch.addingTimeInterval(1)))
        XCTAssertFalse(detector.ingest(bpm: 10, at: epoch.addingTimeInterval(2)))
    }

    func testSeedingFromPersistedBaselineCountsAsReference() {
        var detector = makeDetector()
        let baseline = (-600..<1_800).map {
            SmartWakeHeartRateSample(bpm: 60 + ($0 % 7) - 3, timestamp: epoch.addingTimeInterval(Double($0)))
        }
        detector.seed(baseline)
        let fired = feed(&detector, 1_800..<2_100)
        XCTAssertEqual(fired, epoch.addingTimeInterval(1_890))
    }

    // MARK: Scoring

    private func argmax(_ values: [Double]) -> Int {
        values.indices.max(by: { values[$0] < values[$1] })!
    }

    func testFlatLowVariabilityEpochScoresAsDeep() {
        let scores = SmartWakeLightSleepDetector.logEmissions(
            zHeartRate: -0.5, zVariability: -2, flatnessPercentile: 0.1, cycleFraction: 0.95, zRegularity: nil)
        XCTAssertEqual(argmax(scores), SmartWakeLightSleepDetector.Stage.deep.rawValue)
    }

    func testHighVariabilityEpochScoresAsRem() {
        let scores = SmartWakeLightSleepDetector.logEmissions(
            zHeartRate: 2, zVariability: 2, flatnessPercentile: 0.9, cycleFraction: 0.95, zRegularity: nil)
        XCTAssertEqual(argmax(scores), SmartWakeLightSleepDetector.Stage.rem.rawValue)
    }

    func testLowHeartRateWithOrdinaryVariabilityScoresAsLight() {
        let scores = SmartWakeLightSleepDetector.logEmissions(
            zHeartRate: -1.5, zVariability: 0, flatnessPercentile: 0.6, cycleFraction: 0.95, zRegularity: nil)
        XCTAssertEqual(argmax(scores), SmartWakeLightSleepDetector.Stage.light.rawValue)
    }

    func testRegularBreathingShiftsScoreFromRemToDeep() {
        let plain = SmartWakeLightSleepDetector.logEmissions(
            zHeartRate: 0, zVariability: 0, flatnessPercentile: 0.5, cycleFraction: 0.9, zRegularity: nil)
        let regular = SmartWakeLightSleepDetector.logEmissions(
            zHeartRate: 0, zVariability: 0, flatnessPercentile: 0.5, cycleFraction: 0.9, zRegularity: 2)
        XCTAssertGreaterThan(regular[0], plain[0])
        XCTAssertLessThan(regular[1], plain[1])
        XCTAssertEqual(regular[2], plain[2])
    }

    // MARK: Forward filter

    func testForwardStepNormalisesAndFavoursTheEmittingStage() {
        let light = SmartWakeLightSleepDetector.Stage.light.rawValue
        let favouringLight = [-3.65, -1.16, -0.69, -2.9]
        let first = SmartWakeLightSleepDetector.forwardStep(belief: nil, logEmissions: favouringLight)
        XCTAssertEqual(first.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(first[light], 0.6)

        let favouringRem = [-3.0, 0.5, -0.69, -3.0]
        let second = SmartWakeLightSleepDetector.forwardStep(belief: nil, logEmissions: favouringRem)
        XCTAssertLessThan(second[light], 0.5)
    }

    func testForwardStepNeverEntersDeepOrRemStraightFromAwake() {
        // From a certain "awake" belief, V2's transition row sends deep and rem to ~0 for one step.
        let belief = [0.0, 0.0, 0.0, 1.0]
        let step = SmartWakeLightSleepDetector.forwardStep(belief: belief, logEmissions: [0, 0, 0, 0])
        XCTAssertLessThan(step[0], 1e-6)
        XCTAssertLessThan(step[1], 1e-6)
        XCTAssertEqual(step[2], 0.10, accuracy: 1e-6)
        XCTAssertEqual(step[3], 0.90, accuracy: 1e-6)
    }

    // MARK: Respiration regularity

    /// Beats whose RR follows `rr(t)` at the time of each beat.
    private func beats(from start: Double, seconds: Double, rr: (Double) -> Double) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var time = start
        while time < start + seconds {
            let value = rr(time)
            result.append((time, value))
            time += value / 1000
        }
        return result
    }

    func testRegularBreathingScoresHigherThanIrregular() {
        // 0.25 Hz respiratory sinus arrhythmia: 15 breaths per minute.
        let regular = beats(from: 0, seconds: 210) { 1000 + 100 * sin(2 * Double.pi * 0.25 * $0) }

        var state: UInt64 = 12_345
        let irregular = beats(from: 0, seconds: 210) { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 800 + Double(state >> 33 & 0x7F) * 3   // 800...1181 ms, no rhythm
        }

        let regularScore = SmartWakeLightSleepDetector.respRegularity(regular)
        let irregularScore = SmartWakeLightSleepDetector.respRegularity(irregular)
        XCTAssertNotNil(regularScore)
        XCTAssertNotNil(irregularScore)
        XCTAssertGreaterThan(regularScore ?? 0, 0.3)
        XCTAssertGreaterThan(regularScore ?? 0, (irregularScore ?? 1) + 0.15)
    }

    func testRespirationNeedsEnoughBeats() {
        let few = beats(from: 0, seconds: 8) { _ in 1000 }
        XCTAssertLessThan(few.count, 12)
        XCTAssertNil(SmartWakeLightSleepDetector.respRegularity(few))
    }

    // MARK: Engine hook

    func testMarkTriggeredStopsTheEngineFromFiringASecondReason() {
        let maximum = epoch.addingTimeInterval(3_600)
        let configuration = SmartWakeConfiguration.standard(maximumWakeTime: maximum)
        var engine = SmartWakeEngine(configuration: configuration, baselineSamples: [])
        XCTAssertEqual(engine.markTriggered(.lightSleep), .wake(.lightSleep))
        XCTAssertEqual(engine.markTriggered(.lightSleep), .alreadyTriggered)
        XCTAssertEqual(engine.evaluate(at: maximum), .alreadyTriggered)
    }
}
