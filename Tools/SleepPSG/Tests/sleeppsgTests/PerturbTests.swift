import XCTest
import WhoopProtocol
@testable import SleepRecipe

/// The damage the robustness checks apply must be repeatable and the size it claims. Synthetic streams only.
final class PerturbTests: XCTestCase {

    func testPerturbationsAreDeterministicAndRoughlyTheRequestedSize() {
        let hr = (0..<20_000).map { HRSample(ts: $0, bpm: 60) }
        let a = Perturb.dropHeartRate(hr, fraction: 0.1, seed: 7)
        XCTAssertEqual(a.map { $0.ts }, Perturb.dropHeartRate(hr, fraction: 0.1, seed: 7).map { $0.ts })
        XCTAssertNotEqual(a.map { $0.ts }, Perturb.dropHeartRate(hr, fraction: 0.1, seed: 8).map { $0.ts })
        XCTAssertEqual(Double(hr.count - a.count) / Double(hr.count), 0.1, accuracy: 0.01)
        XCTAssertEqual(Perturb.dropHeartRate(hr, fraction: 0, seed: 1).count, hr.count)
        XCTAssertEqual(Perturb.dropHeartRate(hr, fraction: 1, seed: 1).count, 0)
    }

    func testHolesRemoveExactlyTheNamedRange() {
        let hr = (0..<100).map { HRSample(ts: $0, bpm: 60) }
        let out = Perturb.heartRateHole(hr, from: 40, to: 60)
        XCTAssertEqual(out.count, 80)
        XCTAssertFalse(out.contains { $0.ts >= 40 && $0.ts < 60 })
        let g = (0..<100).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertEqual(Perturb.gravityHole(g, from: 10, to: 11).count, 99)
    }
}
