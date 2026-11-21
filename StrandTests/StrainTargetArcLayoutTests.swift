import XCTest
@testable import Strand

/// The Effort target band is drawn from the ring that is actually drawn, inside its track.
final class StrainTargetArcLayoutTests: XCTestCase {
    private func band(_ recovery: Double) throws -> StrainTargetBand {
        try XCTUnwrap(StrainTargetBand.resolve(recovery: recovery, scale: .whoop))
    }

    func testLiquidGeometryIsTheVesselsOwn() {
        let g = LiquidRender.vesselGeometry(frame: 96)
        XCTAssertEqual(g.radius, 93 * 0.39, accuracy: 0.0001)
        XCTAssertEqual(g.lineWidth, 93 * 0.105, accuracy: 0.0001)
        // Small frames keep the 5 pt minimum line width, exactly as the vessel does.
        XCTAssertEqual(LiquidRender.vesselGeometry(frame: 40).lineWidth, 5, accuracy: 0.0001)
    }

    func testBandStaysInsideTheTrackForEveryTier() throws {
        // The arc view is 2r + lineWidth wide, the ring's own outer extent: nothing can exceed it.
        for recovery in [10.0, 50.0, 90.0] {
            let layout = StrainTargetArcLayout.make(band: try band(recovery), progress: 0.3, ringRadius: 36.3, ringLineWidth: 9.8)
            for f in layout.fill.map({ [$0.lowerBound, $0.upperBound] }) ?? [] { XCTAssertTrue((0...1).contains(f)) }
            for s in layout.tickStarts { XCTAssertTrue(s >= 0 && s + layout.tickLength <= 1 + 1e-9) }
        }
    }

    func testFillStartsAtTheBandWhenProgressIsBelowIt() throws {
        let b = try band(50) // 10-14 of 21
        let layout = StrainTargetArcLayout.make(band: b, progress: 0.1, ringRadius: 40, ringLineWidth: 8)
        XCTAssertEqual(layout.fill?.lowerBound ?? -1, b.fractionLow, accuracy: 1e-9)
        XCTAssertEqual(layout.fill?.upperBound ?? -1, b.fractionHigh, accuracy: 1e-9)
    }

    func testFillStartsAfterTheProgressInsideTheBand() throws {
        let b = try band(50)
        let p = (b.fractionLow + b.fractionHigh) / 2
        let layout = StrainTargetArcLayout.make(band: b, progress: p, ringRadius: 40, ringLineWidth: 8)
        let lower = try XCTUnwrap(layout.fill?.lowerBound)
        XCTAssertGreaterThan(lower, p, "the round cap of the progress arc is not covered")
        XCTAssertEqual(layout.fill?.upperBound ?? -1, b.fractionHigh, accuracy: 1e-9)
    }

    func testBandStaysReadableWhenProgressPassesIt() throws {
        let b = try band(50)
        let layout = StrainTargetArcLayout.make(band: b, progress: 0.95, ringRadius: 40, ringLineWidth: 8)
        XCTAssertNil(layout.fill, "nothing left to fill")
        XCTAssertEqual(layout.tickStarts.count, 2, "the edge ticks still mark the band")
    }

    func testNoProgressDrawsTheWholeBand() throws {
        let b = try band(90)
        let layout = StrainTargetArcLayout.make(band: b, progress: nil, ringRadius: 40, ringLineWidth: 8)
        XCTAssertEqual(layout.fill?.lowerBound ?? -1, b.fractionLow, accuracy: 1e-9)
    }

    func testTicksAreCentredOnTheBandEnds() throws {
        let b = try band(50)
        let l = StrainTargetArcLayout.make(band: b, progress: nil, ringRadius: 40, ringLineWidth: 8)
        XCTAssertEqual(l.tickStarts[0] + l.tickLength / 2, b.fractionLow, accuracy: 1e-9)
        XCTAssertEqual(l.tickStarts[1] + l.tickLength / 2, b.fractionHigh, accuracy: 1e-9)
    }
}
