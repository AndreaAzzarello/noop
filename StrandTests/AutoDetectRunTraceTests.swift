import XCTest
import StrandAnalytics
@testable import Strand

/// Every exit of `Repository.autoDetectCandidate` must leave a line the Test Centre can count, otherwise
/// the report says "mode was on but produced NO trace" and nobody learns why there is no suggestion.
final class AutoDetectRunTraceTests: XCTestCase {

    func testEntryAndSkipLines() {
        XCTAssertEqual(AutoDetectRunTrace.entry(daysBack: 2, enabled: true),
                       "autoDetect run daysBack=2 enabled=true")
        XCTAssertEqual(AutoDetectRunTrace.entry(daysBack: 2, enabled: false),
                       "autoDetect run daysBack=2 enabled=false")
        XCTAssertEqual(AutoDetectRunTrace.skipToggleOff(), "autoDetect skip why=toggleOff")
        XCTAssertEqual(AutoDetectRunTrace.skipTooFewSamples(count: 1),
                       "autoDetect skip why=tooFewHrSamples hrSamples=1 needed=2")
    }

    func testSelectionLines() {
        XCTAssertEqual(AutoDetectRunTrace.selection(offered: 1, picked: true),
                       "autoDetect select offered=1 picked=yes")
        XCTAssertEqual(AutoDetectRunTrace.selection(offered: 0, picked: false),
                       "autoDetect select offered=0 picked=no why=noWindows")
        XCTAssertEqual(AutoDetectRunTrace.selection(offered: 2, picked: false),
                       "autoDetect select offered=2 picked=no why=allDismissed")
    }

    /// The report's completeness check looks for the `autoDetect` token in the workouts domain.
    func testEveryLineCarriesTheCompletenessToken() {
        let lines = [
            AutoDetectRunTrace.entry(daysBack: 2, enabled: true),
            AutoDetectRunTrace.skipToggleOff(),
            AutoDetectRunTrace.skipTooFewSamples(count: 0),
            AutoDetectRunTrace.selection(offered: 0, picked: false),
        ]
        for line in lines { XCTAssertTrue(line.hasPrefix("autoDetect "), line) }
    }
}
