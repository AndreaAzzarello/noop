import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the Italian rendering of the Week-in-review focal points and that English stays byte-identical to the
/// engine's own sentences (the text shared with the Android twin).
final class WeeklyDigestLocalizationTests: XCTestCase {

    private func bundle(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"),
                                 "\(lang).lproj missing from the app bundle")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func mover(_ m: WeeklyMetric, _ dir: Int, _ mag: WeeklyFocalPoint.Magnitude,
                       _ a: Int, _ b: Int, _ g: Int) -> WeeklyFocalPoint {
        .mover(metric: m, direction: dir, magnitude: mag, thisAvg: a, lastAvg: b, goodness: g)
    }

    private func it(_ item: WeeklyFocalPoint) throws -> String {
        WeeklyDigestText.text(item, bundle: try bundle("it"), language: "it")
    }

    func testItalianPercentUsesDel() throws {
        XCTAssertEqual(try it(mover(.effort, -1, .percent(57), 14, 33, -1)),
                       "Sforzo in calo del 57% rispetto alla settimana scorsa (media 14 contro 33), vale un'occhiata.")
        XCTAssertEqual(try it(mover(.charge, 1, .percent(12), 70, 62, 1)),
                       "Carica in aumento del 12% rispetto alla settimana scorsa (media 70 contro 62), un buon segno.")
    }

    func testItalianAmountUsesDiAndDecimalComma() throws {
        XCTAssertEqual(try it(mover(.rest, 1, .amount(3.2, unit: ""), 80, 77, 1)),
                       "Riposo in aumento di 3,2 pti rispetto alla settimana scorsa (media 80 contro 77), un buon segno.")
        XCTAssertEqual(try it(mover(.rhr, 1, .amount(4.0, unit: "bpm"), 58, 54, -1)),
                       "FC a riposo in aumento di 4,0 bpm rispetto alla settimana scorsa (media 58 contro 54), vale un'occhiata.")
        XCTAssertEqual(try it(mover(.hrv, -1, .amount(6.5, unit: "ms"), 50, 56, -1)),
                       "HRV in calo di 6,5 ms rispetto alla settimana scorsa (media 50 contro 56), vale un'occhiata.")
    }

    func testItalianFixedLines() throws {
        XCTAssertEqual(try it(.balance(.underloaded)),
                       "Questa settimana hai accumulato più Carica di quanta ne hai spesa: c'è margine per spingere, se vuoi.")
        XCTAssertEqual(try it(.earlyWeek(days: 1)),
                       "Solo 1 giorno di questa settimana finora: troppo presto per parlare di una tendenza.")
        XCTAssertEqual(try it(.earlyWeek(days: 2)),
                       "Solo 2 giorni di questa settimana finora: troppo presto per parlare di una tendenza.")
        XCTAssertEqual(try it(.steadyRest(sd: 2.5)),
                       "Settimana stabile: il Riposo è rimasto costante (±2,5 pti) e nient'altro si è mosso molto.")
    }

    /// English output must equal the engine's `englishText` for every key, so nothing drifts from Android.
    func testEnglishIsByteIdenticalToEngine() throws {
        let en = try bundle("en")
        let items: [WeeklyFocalPoint] = [
            mover(.effort, -1, .percent(57), 14, 33, -1),
            mover(.charge, 1, .percent(12), 70, 62, 1),
            mover(.rest, 1, .amount(3.2, unit: ""), 80, 77, 1),
            mover(.rhr, -1, .amount(4.0, unit: "bpm"), 54, 58, 1),
            mover(.hrv, 1, .amount(6.5, unit: "ms"), 56, 50, 1),
            mover(.hrv, 1, .percent(9), 56, 50, 0),
            .balance(.overreaching), .balance(.balanced), .balance(.underloaded), .balance(.insufficient),
            .earlyWeek(days: 1), .earlyWeek(days: 2), .sparseLastWeek(days: 1), .sparseLastWeek(days: 2),
            .steadyRest(sd: 2.5), .steady,
        ]
        for item in items {
            XCTAssertEqual(WeeklyDigestText.text(item, bundle: en, language: "en"), item.englishText)
        }
    }

    func testEveryKeyResolvesInItalian() throws {
        // A missing key would fall back to the English sentence; assert none does.
        let items: [WeeklyFocalPoint] = [
            .balance(.overreaching), .balance(.balanced), .balance(.insufficient),
            .sparseLastWeek(days: 1), .sparseLastWeek(days: 3), .steady,
            mover(.charge, -1, .percent(20), 50, 62, -1),
            mover(.charge, 1, .amount(1.5, unit: ""), 64, 62, 1),
        ]
        for item in items {
            XCTAssertNotEqual(try it(item), item.englishText, "untranslated: \(item.englishText)")
        }
    }
}
