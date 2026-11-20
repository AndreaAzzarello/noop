import XCTest
@testable import Strand

final class StrainTargetBandTests: XCTestCase {

    func testUnknownRecoveryHasNoBand() {
        XCTAssertNil(StrainTargetBand.resolve(recovery: nil, scale: .whoop))
        XCTAssertNil(StrainTargetBand.resolve(recovery: nil, scale: .hundred))
    }

    func testBandsMatchTheApprovedRecoveryMapping() {
        let cases: [(Double, Int, Int)] = [
            (0, 4, 10), (33.9, 4, 10), (34, 10, 14), (66.9, 10, 14), (67, 14, 18), (100, 14, 18),
        ]
        for (recovery, lo, hi) in cases {
            let band = StrainTargetBand.resolve(recovery: recovery, scale: .whoop)
            XCTAssertEqual(band?.low21, lo, "recovery \(recovery)")
            XCTAssertEqual(band?.high21, hi, "recovery \(recovery)")
        }
    }

    func testWhoopScaleShowsTheAxisValues() {
        let band = StrainTargetBand.resolve(recovery: 50, scale: .whoop)
        XCTAssertEqual(band?.displayLow, 10)
        XCTAssertEqual(band?.displayHigh, 14)
    }

    func testHundredScaleRescalesTheDisplayedValuesOnly() {
        let band = StrainTargetBand.resolve(recovery: 50, scale: .hundred)
        XCTAssertEqual(band?.displayLow, 48)
        XCTAssertEqual(band?.displayHigh, 67)
        XCTAssertEqual(band?.low21, 10)
        XCTAssertEqual(band?.high21, 14)
    }

    func testRingFractionsAreIdenticalOnBothScales() throws {
        let a = try XCTUnwrap(StrainTargetBand.resolve(recovery: 80, scale: .whoop))
        let b = try XCTUnwrap(StrainTargetBand.resolve(recovery: 80, scale: .hundred))
        XCTAssertEqual(a.fractionLow, b.fractionLow)
        XCTAssertEqual(a.fractionHigh, b.fractionHigh)
        XCTAssertEqual(a.fractionLow, 14.0 / 21.0, accuracy: 1e-12)
        XCTAssertEqual(a.fractionHigh, 18.0 / 21.0, accuracy: 1e-12)
    }
}
