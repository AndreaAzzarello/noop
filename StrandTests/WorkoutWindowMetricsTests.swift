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
