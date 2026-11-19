import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Pins what the quick workout edit writes (the row it saves) and the chips it offers. Synthetic data only.
final class WorkoutQuickEditTests: XCTestCase {

    private let t0 = 1_800_000_000
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(t0 + 86_400)) }

    /// A saved strap session with every captured field set, so a carry-over regression shows.
    private var row: WorkoutRow {
        WorkoutRow(startTs: t0, endTs: t0 + 3600, sport: "detected", source: "my-whoop-noop", durationS: 3600,
                   energyKcal: 500, avgHr: 130, maxHr: 175, strain: 12.5, distanceM: 4200,
                   zonesJSON: "{\"z\":1}", notes: "n", steps: 4000)
    }

    /// One reading every 10 s for two hours from `t0`: 100 bpm for the first hour, 150 for the second.
    private var samples: [HRSample] {
        (0..<720).map { HRSample(ts: t0 + $0 * 10, bpm: $0 < 360 ? 100 : 150) }
    }

    private func date(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t0 + offset)) }

    // MARK: Row

    func testUntouchedSpanKeepsTheStoredAverageAndEverythingCaptured() throws {
        let built = try XCTUnwrap(WorkoutQuickEdit.rebuilt(row: row, start: date(0), end: date(3600),
                                                           sport: "Karate", samples: samples, now: now))
        XCTAssertEqual(built.sport, "Karate", "stored verbatim in English")
        XCTAssertEqual(built.source, "manual")
        XCTAssertEqual(built.avgHr, 130, "span untouched: stored average kept")
        XCTAssertEqual(built.energyKcal, 500)
        XCTAssertEqual(built.distanceM, 4200)
        XCTAssertEqual(built.maxHr, 175)
        XCTAssertEqual(built.strain, 12.5)
        XCTAssertEqual(built.zonesJSON, "{\"z\":1}")
        XCTAssertEqual(built.steps, 4000)
        XCTAssertEqual(built.startTs, t0)
        XCTAssertEqual(built.endTs, t0 + 3600)
        XCTAssertEqual(built.durationS, 3600)
    }

    func testMovingAnEdgeRecomputesTheAverageOverTheNewWindow() throws {
        // Dropping the first 30 min leaves 30 min at 100 and 60 min at 150: mean 133.3 → 133.
        let built = try XCTUnwrap(WorkoutQuickEdit.rebuilt(row: row, start: date(1800), end: date(7200),
                                                           sport: "Karate", samples: samples, now: now))
        XCTAssertEqual(built.startTs, t0 + 1800)
        XCTAssertEqual(built.durationS, 5400)
        XCTAssertEqual(built.avgHr, 133)
        XCTAssertEqual(WorkoutQuickEdit.avgHr(row: row, start: t0 + 1800, end: t0 + 7200, samples: samples), 133)
    }

    func testMovedEdgeWithoutReadingsFallsBackToTheStoredAverage() {
        XCTAssertEqual(WorkoutQuickEdit.avgHr(row: row, start: t0 + 600, end: t0 + 3600, samples: []), 130)
    }

    func testInvalidSpansAndSportsAreRefused() {
        func build(_ start: Int, _ end: Int, _ sport: String = "Karate") -> WorkoutRow? {
            WorkoutQuickEdit.rebuilt(row: row, start: date(start), end: date(end), sport: sport,
                                     samples: samples, now: now)
        }
        XCTAssertNil(build(3600, 3600), "end must be after start")
        XCTAssertNil(build(3600, 3000))
        XCTAssertNil(build(0, 30), "under a minute")
        XCTAssertNil(build(0, 3600, "  "), "blank sport")
        XCTAssertNil(WorkoutQuickEdit.rebuilt(row: row, start: date(0), end: date(3600), sport: "Karate",
                                              samples: samples, now: date(1800)), "end in the future")
    }

    func testTheActivityTokenIsStoredAsIs() throws {
        let built = try XCTUnwrap(WorkoutQuickEdit.rebuilt(row: row, start: date(0), end: date(3600),
                                                           sport: "Activity", samples: samples, now: now))
        XCTAssertEqual(built.sport, "Activity")
    }

    // MARK: Chips

    func testOptionsStartWithActivityThenTheChoiceThenRecentsThenCommon() {
        let options = SportChipOptions.options(selected: "Karate", recents: ["Judo", "Running"],
                                               common: ["Running", "Walking"])
        XCTAssertEqual(options, ["Activity", "Karate", "Judo", "Running", "Walking"])
    }

    func testOptionsDropDuplicatesCaseInsensitivelyKeepingTheFirstSpelling() {
        let options = SportChipOptions.options(selected: "running", recents: ["RUNNING", "Yoga"],
                                               common: ["Running", "yoga", "Walking"])
        XCTAssertEqual(options, ["Activity", "running", "Yoga", "Walking"])
    }

    func testTheSelectedActivityTokenIsNotListedTwice() {
        let options = SportChipOptions.options(selected: "Activity", recents: [], common: ["Running"])
        XCTAssertEqual(options, ["Activity", "Running"])
    }

    func testBlankNamesAreIgnoredAndSameIsCaseInsensitive() {
        XCTAssertEqual(SportChipOptions.options(selected: " ", recents: ["", " Yoga "], common: []),
                       ["Activity", "Yoga"])
        XCTAssertTrue(SportChipOptions.same("Karate", " karate "))
        XCTAssertFalse(SportChipOptions.same("Karate", "Judo"))
    }

    // MARK: Names

    func testDisplayNameReadsDetectedAsActivityAndLeavesUnknownSportsAlone() {
        XCTAssertEqual(SportDisplayName.localized("detected"), String(localized: "Activity"))
        XCTAssertEqual(SportDisplayName.localized("Karate"), "Karate")
        XCTAssertEqual(SportDisplayName.localized("TraditionalStrengthTraining"), "Traditional Strength Training")
    }

    func testCommonSportsHaveAnItalianNameOrStayEnglish() {
        // Localized when the test host runs in Italian, the English name otherwise.
        XCTAssertTrue(["Cycling", "Ciclismo"].contains(SportDisplayName.localized("Cycling")))
        XCTAssertTrue(["Strength Training", "Allenamento di forza"].contains(SportDisplayName.localized("Strength Training")))
    }
}
