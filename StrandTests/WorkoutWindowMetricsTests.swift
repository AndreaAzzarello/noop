import XCTest
@testable import Strand

/// Pins the pure rules behind the extra workout-detail tiles: which source wins for steps, that an empty
/// source is skipped rather than shown as 0, which sports get the court Steps tile, and the Effort readout.
final class WorkoutWindowMetricsTests: XCTestCase {

    // MARK: Step sources

    func testImportedCountWinsOverStrapAndPhone() {
        let s = WorkoutWindowMetrics.resolveSteps(imported: 4_200, strapTicks: 9_000, ticksPerStep: 1,
                                                  pedometer: 7_000)
        XCTAssertEqual(s, WorkoutWindowMetrics.Steps(count: 4_200, source: .imported))
    }

    func testStrapWinsOverPhoneAndIsScaledByTicksPerStep() {
        let s = WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: 9_000, ticksPerStep: 2,
                                                  pedometer: 7_000)
        XCTAssertEqual(s, WorkoutWindowMetrics.Steps(count: 4_500, source: .strap))
    }

    func testTicksPerStepBelowTheFloorIsClampedToHalf() {
        let s = WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: 1_000, ticksPerStep: 0.1,
                                                  pedometer: nil)
        XCTAssertEqual(s?.count, 2_000)
        XCTAssertEqual(WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: 1_000, ticksPerStep: 0,
                                                         pedometer: nil)?.count, 2_000)
    }

    func testPhoneIsTheLastResort() {
        let s = WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: nil, ticksPerStep: 1,
                                                  pedometer: 3_100)
        XCTAssertEqual(s, WorkoutWindowMetrics.Steps(count: 3_100, source: .phone))
    }

    func testZeroAndNegativeSourcesAreSkippedNotShown() {
        XCTAssertEqual(WorkoutWindowMetrics.resolveSteps(imported: 0, strapTicks: 0, ticksPerStep: 1,
                                                         pedometer: 2_500),
                       WorkoutWindowMetrics.Steps(count: 2_500, source: .phone))
        XCTAssertNil(WorkoutWindowMetrics.resolveSteps(imported: 0, strapTicks: -5, ticksPerStep: 1,
                                                       pedometer: 0))
        XCTAssertNil(WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: nil, ticksPerStep: 1,
                                                       pedometer: nil))
    }

    func testStrapTicksThatRoundToZeroFallThroughToThePhone() {
        // 1 tick at 4 ticks/step is 0.25 of a step: no strap count, so the phone is used.
        let s = WorkoutWindowMetrics.resolveSteps(imported: nil, strapTicks: 1, ticksPerStep: 4,
                                                  pedometer: 800)
        XCTAssertEqual(s, WorkoutWindowMetrics.Steps(count: 800, source: .phone))
    }

    // MARK: Which sports

    func testCourtAndFieldSportsGetTheTile() {
        for sport in ["Tennis", "tennis", "  Padel ", "Soccer", "Table tennis", "Field hockey"] {
            XCTAssertTrue(WorkoutWindowMetrics.showsCourtSteps(sport: sport), sport)
        }
    }

    func testOnFootAndOtherSportsNeverGetTheCourtTile() {
        // On-foot sports keep WorkoutDetailView's own tile, so a session cannot carry two.
        for sport in ["Running", "Walking", "Hiking", "Treadmill run"] {
            XCTAssertFalse(WorkoutWindowMetrics.showsCourtSteps(sport: sport), sport)
        }
        for sport in ["Cycling", "Yoga", "Swimming", "Strength Training", "", "Unknown sport"] {
            XCTAssertFalse(WorkoutWindowMetrics.showsCourtSteps(sport: sport), sport)
        }
    }

    func testEveryCourtSportIsACatalogueSport() {
        let catalogue = Set(WorkoutCatalog.all.map(\.name))
        XCTAssertTrue(WorkoutWindowMetrics.courtStepSports.isSubset(of: catalogue),
                      "unknown: \(WorkoutWindowMetrics.courtStepSports.subtracting(catalogue))")
    }

    // MARK: Estimated distance

    private func estimate(sport: String = "Running", steps: Int = 3_000, durationS: Double = 1_800,
                          avgHr: Int? = 150, hrMax: Double = 190, heightCm: Double = 180,
                          recorded: Double? = nil) -> WorkoutWindowMetrics.DistanceEstimate? {
        WorkoutWindowMetrics.estimateDistance(sport: sport, steps: steps, durationS: durationS, avgHr: avgHr,
                                              hrMax: hrMax, heightCm: heightCm, recordedDistanceM: recorded)
    }

    func testDistanceEstimateSportSet() {
        for sport in ["Running", "Walking", "Hiking", "Treadmill run", "Treadmill walk", "Tennis", "padel",
                      " Soccer ", "Basketball", "Handball", "Rugby", "Field hockey", "Lacrosse",
                      "Squash", "Badminton", "Pickleball"] {
            XCTAssertTrue(WorkoutWindowMetrics.supportsDistanceEstimate(sport: sport), sport)
        }
        for sport in ["Table tennis", "Volleyball", "Cycling", "Pool swim", "Strength", "Yoga", "", "Nope"] {
            XCTAssertFalse(WorkoutWindowMetrics.supportsDistanceEstimate(sport: sport), sport)
        }
    }

    func testEveryDistanceEstimateSportIsACatalogueSport() {
        let catalogue = Set(WorkoutCatalog.all.map(\.name))
        XCTAssertTrue(WorkoutWindowMetrics.distanceEstimateSports.isSubset(of: catalogue))
    }

    func testTennisExample() throws {
        // 5457 steps over 66 min: 82.7 spm, racket factor 0.35, 178 cm -> 0.623 m per step.
        let e = try XCTUnwrap(estimate(sport: "Tennis", steps: 5_457, durationS: 66 * 60, avgHr: 130,
                                       heightCm: 178))
        XCTAssertEqual(e.meters, 5_457 * 1.78 * 0.35, accuracy: 1)
        XCTAssertEqual(e.meters, 3_399.8, accuracy: 1)
    }

    func testRecordedDistanceWins() {
        XCTAssertNil(estimate(recorded: 5_000))
        XCTAssertNotNil(estimate(recorded: 0))
        XCTAssertNotNil(estimate(recorded: nil))
    }

    func testStepAndDurationThresholds() {
        // 10 min windows keep cadence in range (50 spm at 500 steps), so only the step floor bites.
        XCTAssertNil(estimate(steps: 499, durationS: 600))
        XCTAssertNotNil(estimate(steps: 500, durationS: 600))
        // Duration floor: 1000 steps in 299 s is 200 spm (in range), still rejected for being under 5 min.
        XCTAssertNil(estimate(steps: 1_000, durationS: 299))
        XCTAssertNotNil(estimate(steps: 1_000, durationS: 300))
    }

    func testCadenceBounds() {
        // 30 min: 1500 steps = 50 spm (in), 1499 = just under (out); 6600 = 220 spm (in), 6601 out.
        XCTAssertNotNil(estimate(steps: 1_500, durationS: 1_800))
        XCTAssertNil(estimate(steps: 1_499, durationS: 1_800))
        XCTAssertNotNil(estimate(steps: 6_600, durationS: 1_800))
        XCTAssertNil(estimate(steps: 6_601, durationS: 1_800))
    }

    func testShortestAllowedSessionStillClearsTheDistanceFloor() throws {
        // The 200 m floor is a backstop: with >= 500 steps and >= 120 cm the smallest result is
        // 500 x 1.2 x 0.35 = 210 m (racket), so the other guards are what bite first.
        let e = try XCTUnwrap(estimate(sport: "Tennis", steps: 500, durationS: 600, avgHr: 90, heightCm: 120))
        XCTAssertEqual(e.meters, 210, accuracy: 1e-9)
    }

    func testHeightOutOfRangeFallsBackTo170() throws {
        let fallback = try XCTUnwrap(estimate(sport: "Walking", avgHr: 90, heightCm: 0))
        let explicit = try XCTUnwrap(estimate(sport: "Walking", avgHr: 90, heightCm: 170))
        XCTAssertEqual(fallback.meters, explicit.meters, accuracy: 0.001)
        let tall = try XCTUnwrap(estimate(sport: "Walking", avgHr: 90, heightCm: 300))
        XCTAssertEqual(tall.meters, explicit.meters, accuracy: 0.001)
    }

    func testWalkRunTransitionByCadence() throws {
        // 30 min windows: 120 spm = 3600 steps, 135 = 4050, 150 = 4500. 180 cm height.
        let walk = try XCTUnwrap(estimate(steps: 3_600))
        XCTAssertEqual(walk.stepLengthM, 1.8 * 0.415, accuracy: 1e-9)
        let mid = try XCTUnwrap(estimate(steps: 4_050))
        XCTAssertEqual(mid.stepLengthM, 1.8 * (0.415 + 0.5 * 0.135), accuracy: 1e-9)
        let run = try XCTUnwrap(estimate(steps: 4_500))
        XCTAssertEqual(run.stepLengthM, 1.8 * 0.55, accuracy: 1e-9)
        let faster = try XCTUnwrap(estimate(steps: 5_400))
        XCTAssertEqual(faster.stepLengthM, 1.8 * 0.55, accuracy: 1e-9)
    }

    func testLowHeartRateKeepsTheWalkFactor() throws {
        // 150 spm would be a run, but avg HR under 60% of max says otherwise.
        let e = try XCTUnwrap(estimate(steps: 4_500, avgHr: 100, hrMax: 190))
        XCTAssertEqual(e.stepLengthM, 1.8 * 0.415, accuracy: 1e-9)
        let boundary = try XCTUnwrap(estimate(steps: 4_500, avgHr: 114, hrMax: 190)) // exactly 60%
        XCTAssertEqual(boundary.stepLengthM, 1.8 * 0.55, accuracy: 1e-9)
        // No HR at all: cadence decides.
        let noHr = try XCTUnwrap(estimate(steps: 4_500, avgHr: nil))
        XCTAssertEqual(noHr.stepLengthM, 1.8 * 0.55, accuracy: 1e-9)
    }

    func testRacketFactorIgnoresCadenceAndHeartRate() throws {
        let e = try XCTUnwrap(estimate(sport: "Padel", steps: 4_500, avgHr: 170))
        XCTAssertEqual(e.stepLengthM, 1.8 * 0.35, accuracy: 1e-9)
    }

    // MARK: Estimated distance caption

    func testDistanceTextUsesLocaleDecimalAndUnit() {
        let it = Locale(identifier: "it_IT"), en = Locale(identifier: "en_US")
        XCTAssertEqual(WorkoutWindowMetrics.estimatedDistanceText(meters: 3_400, system: .metric, locale: it), "3,4 km")
        XCTAssertEqual(WorkoutWindowMetrics.estimatedDistanceText(meters: 3_400, system: .metric, locale: en), "3.4 km")
        // 5000 m = 3.1069 mi.
        XCTAssertEqual(WorkoutWindowMetrics.estimatedDistanceText(meters: 5_000, system: .imperial, locale: en), "3.1 mi")
        XCTAssertEqual(WorkoutWindowMetrics.estimatedDistanceText(meters: 5_000, system: .imperial, locale: it), "3,1 mi")
    }

    func testCaptionIsJustTheSourceWithoutAnEstimate() {
        XCTAssertEqual(WorkoutWindowMetrics.stepsCaption(source: "strap", estimate: nil, system: .metric,
                                                         locale: Locale(identifier: "en_US")), "strap")
    }

    func testCaptionAppendsTheEstimate() {
        let e = WorkoutWindowMetrics.DistanceEstimate(meters: 3_400, stepLengthM: 0.62, cadenceSpm: 83)
        XCTAssertEqual(WorkoutWindowMetrics.stepsCaption(source: "strap", estimate: e, system: .metric,
                                                         locale: Locale(identifier: "en_US")), "strap · ≈ 3.4 km")
    }

    // MARK: Effort

    func testMissingOrNonFiniteStrainHasNoEffortTile() {
        XCTAssertNil(WorkoutWindowMetrics.effort(strain: nil, scale: .hundred))
        XCTAssertNil(WorkoutWindowMetrics.effort(strain: .nan, scale: .hundred))
        XCTAssertNil(WorkoutWindowMetrics.effort(strain: .infinity, scale: .whoop))
    }

    func testEffortUsesTheSameFormatterAsTheEffortCard() {
        let hundred = WorkoutWindowMetrics.effort(strain: 67.3, scale: .hundred)
        XCTAssertEqual(hundred?.value, UnitFormatter.effortDisplay(67.3, scale: .hundred))
        XCTAssertEqual(hundred?.value, "67.3")
        let whoop = WorkoutWindowMetrics.effort(strain: 50, scale: .whoop)
        XCTAssertEqual(whoop?.value, UnitFormatter.effortDisplay(50, scale: .whoop))
        XCTAssertEqual(whoop?.value, "10.5")
        XCTAssertEqual(whoop?.scale, .whoop)
    }
}
