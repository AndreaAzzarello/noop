import XCTest
@testable import Strand

final class ForkThreadAttributionTests: XCTestCase {
    typealias C = ForkEnergyCounters
    private func slice(_ id: UInt64, _ name: String, _ ms: Int, main: Bool = false) -> C.ThreadSlice {
        C.ThreadSlice(id: id, name: name, cpuMs: ms, isMain: main)
    }

    func testBuckets() {
        XCTAssertEqual(C.bucket(threadName: "", isMain: true), .cpuThrMainMs)
        XCTAssertEqual(C.bucket(threadName: "", isMain: false), .cpuThrUnnamedMs)
        XCTAssertEqual(C.bucket(threadName: "com.apple.root.user-initiated-qos.cooperative", isMain: false), .cpuThrCoopMs)
        XCTAssertEqual(C.bucket(threadName: "com.apple.root.default-qos", isMain: false), .cpuThrDispatchMs)
        XCTAssertEqual(C.bucket(threadName: "com.apple.CoreBluetooth", isMain: false), .cpuThrNamedMs)
    }

    func testDeltasAreBookedByBucketAndTheRestIsExited() {
        let previous: [UInt64: Int] = [1: 1000, 2: 500]
        let slices = [slice(1, "", 1400, main: true), slice(2, "com.apple.root.default-qos", 800),
                      slice(3, "", 50)]   // thread 3 is new: counted in full
        let split = C.attribute(slices: slices, previous: previous, processDelta: 1000)
        XCTAssertEqual(split.byBucket[.cpuThrMainMs], 400)
        XCTAssertEqual(split.byBucket[.cpuThrDispatchMs], 300)
        XCTAssertEqual(split.byBucket[.cpuThrUnnamedMs], 50)
        XCTAssertEqual(split.exited, 250)   // 1000 - (400 + 300 + 50)
    }

    func testExitedNeverGoesNegative() {
        let split = C.attribute(slices: [slice(1, "", 900, main: true)], previous: [1: 0], processDelta: 100)
        XCTAssertEqual(split.exited, 0)
    }

    func testTheLiveSamplerSeesThisProcess() {
        let slices = C.threadSlices()
        XCTAssertFalse(slices.isEmpty)
        XCTAssertEqual(slices.filter(\.isMain).count, 1)
        XCTAssertGreaterThan(slices.reduce(0) { $0 + $1.cpuMs }, 0)
    }
}
