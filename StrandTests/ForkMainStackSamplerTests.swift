import XCTest
@testable import Strand

// fork-perf: TEMP — pure parts of the main-thread stack sampler. Remove with the sampler commit.

final class ForkMainStackSamplerTests: XCTestCase {

    typealias Sampler = ForkMainStackSampler

    /// A fake stack: address → word.
    private struct FakeMemory: ForkStackMemory {
        var words: [UInt: UInt]
        func load(_ address: UInt) -> UInt? { address & 7 == 0 ? words[address] : nil }
    }

    /// Frame records at `base`, `base+0x40`, … each pointing to the next, with return addresses `returns`.
    private func chain(base: UInt, returns: [UInt]) -> FakeMemory {
        var words: [UInt: UInt] = [:]
        for (i, ret) in returns.enumerated() {
            let at = base + UInt(i) * 0x40
            words[at] = i == returns.count - 1 ? 0 : at + 0x40
            words[at + 8] = ret
        }
        return FakeMemory(words: words)
    }

    private func walk(pc: UInt = 0x1000, lr: UInt = 0x2000, fp: UInt, memory: FakeMemory, max: Int = 24) -> [UInt] {
        let out = UnsafeMutablePointer<UInt>.allocate(capacity: max)
        defer { out.deallocate() }
        let r = Sampler.StackWalker.walk(pc: pc, lr: lr, fp: fp, memory: memory, maxFrames: max, out: out)
        return (0..<r.count).map { out[$0] }
    }

    func testMaskPACKeepsTheLow39Bits() {
        XCTAssertEqual(Sampler.maskPAC(0xFFFF_8001_2345_6789), 0x0000_0001_2345_6789)
        XCTAssertEqual(Sampler.maskPAC(0x1_0000_1000), 0x1_0000_1000)
    }

    func testWalkListsPCLRThenReturnAddresses() {
        let m = chain(base: 0x7000, returns: [0x3000, 0x4000, 0x5000])
        XCTAssertEqual(walk(fp: 0x7000, memory: m), [0x1000, 0x2000, 0x3000, 0x4000, 0x5000])
    }

    func testWalkDoesNotRepeatLRWhenTheLeafBuiltItsFrame() {
        let m = chain(base: 0x7000, returns: [0x2000, 0x4000])
        XCTAssertEqual(walk(fp: 0x7000, memory: m), [0x1000, 0x2000, 0x4000])
    }

    func testWalkStripsPACFromReturnAddresses() {
        let m = chain(base: 0x7000, returns: [0xFFFF_8000_0000_3000])
        XCTAssertEqual(walk(fp: 0x7000, memory: m), [0x1000, 0x2000, 0x3000])
    }

    func testWalkStopsAtMisalignedOrNullFramePointer() {
        let m = chain(base: 0x7000, returns: [0x3000])
        XCTAssertEqual(walk(fp: 0x7008, memory: m), [0x1000, 0x2000])
        XCTAssertEqual(walk(fp: 0, memory: m), [0x1000, 0x2000])
    }

    func testWalkStopsOutsideTheStack() {
        var m = chain(base: 0x7000, returns: [0x3000, 0x4000])
        m.words[0x7000] = 0x9990   // the next record is not in the fake stack
        XCTAssertEqual(walk(fp: 0x7000, memory: m), [0x1000, 0x2000, 0x3000])
    }

    func testWalkStopsOnACycleAndOnAFramePointerThatDoesNotGrow() {
        var m = chain(base: 0x7000, returns: [0x3000, 0x4000, 0x5000])
        m.words[0x7040] = 0x7000   // points back
        XCTAssertEqual(walk(fp: 0x7000, memory: m), [0x1000, 0x2000, 0x3000, 0x4000])
    }

    func testWalkIsCutAtTheFrameLimitAndSaysSo() {
        let returns = (0..<40).map { UInt(0x3000 + $0 * 0x10) }
        let m = chain(base: 0x7000, returns: returns)
        let out = UnsafeMutablePointer<UInt>.allocate(capacity: 24)
        defer { out.deallocate() }
        let r = Sampler.StackWalker.walk(pc: 0x1000, lr: 0x2000, fp: 0x7000, memory: m, maxFrames: 24, out: out)
        XCTAssertEqual(r.count, 24)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(out[23], UInt(0x3000 + 21 * 0x10))
    }

    func testClassifierNeedsHalfTheIntervalInCPU() {
        XCTAssertTrue(Sampler.isCPUSample(cpuDeltaMicros: 10_000, intervalMicros: 20_000))
        XCTAssertTrue(Sampler.isCPUSample(cpuDeltaMicros: 20_000, intervalMicros: 20_000))
        XCTAssertFalse(Sampler.isCPUSample(cpuDeltaMicros: 9_999, intervalMicros: 20_000))
        XCTAssertFalse(Sampler.isCPUSample(cpuDeltaMicros: 0, intervalMicros: 20_000))
        XCTAssertFalse(Sampler.isCPUSample(cpuDeltaMicros: 5_000, intervalMicros: 0), "no interval, no verdict")
        // A tick that overslept to 30 ms needs 15 ms.
        XCTAssertFalse(Sampler.isCPUSample(cpuDeltaMicros: 14_000, intervalMicros: 30_000))
        XCTAssertTrue(Sampler.isCPUSample(cpuDeltaMicros: 15_000, intervalMicros: 30_000))
    }

    func testImageGroups() {
        let app = "/var/containers/Bundle/Application/X/NOOP.app"
        XCTAssertEqual(Sampler.ImageGroup.classify(path: app + "/NOOP", appBundlePath: app).group, "app")
        XCTAssertEqual(Sampler.ImageGroup.classify(
            path: "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", appBundlePath: app).group, "CoreBluetooth")
        for name in ["SwiftUI", "SwiftUICore", "AttributeGraph"] {
            XCTAssertEqual(Sampler.ImageGroup.classify(
                path: "/System/Library/Frameworks/\(name).framework/\(name)", appBundlePath: app).group, "SwiftUI")
        }
        XCTAssertEqual(Sampler.ImageGroup.classify(path: "/usr/lib/system/libdispatch.dylib", appBundlePath: app).group, "libdispatch")
        XCTAssertEqual(Sampler.ImageGroup.classify(
            path: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", appBundlePath: app).group, "Foundation")
        let other = Sampler.ImageGroup.classify(path: "/usr/lib/system/libsystem_kernel.dylib", appBundlePath: app)
        XCTAssertEqual(other.group, "other")
        XCTAssertEqual(other.base, "libsystem_kernel.dylib")
    }

    private func sample(_ frames: [String], image: String = "app", detail: String? = nil, app: String = "f") -> Sampler.Aggregate.Sample {
        .init(frames: frames, imageGroup: image, imageDetail: detail, appFrame: app)
    }

    func testAggregateKeysOnTheFirstSixFrames() {
        var a = Sampler.Aggregate()
        a.addCPU(sample(["a", "b", "c", "d", "e", "f", "g1"]), limits: Sampler.Aggregate.hourLimits)
        a.addCPU(sample(["a", "b", "c", "d", "e", "f", "g2"]), limits: Sampler.Aggregate.hourLimits)
        XCTAssertEqual(a.cpu, 2)
        XCTAssertEqual(a.stacks, ["a < b < c < d < e < f": 2])
        XCTAssertEqual(a.leaves, ["a": 2])
    }

    func testAggregateRefusesNewKeysPastTheLimitButKeepsCounting() {
        var a = Sampler.Aggregate()
        let limits = Sampler.Aggregate.Limits(stacks: 2, leaves: 2, appFrames: 2, images: 2)
        var overflow = 0
        for i in 0..<4 { overflow += a.addCPU(sample(["s\(i)"], app: "p\(i)"), limits: limits) }
        a.addCPU(sample(["s0"], app: "p0"), limits: limits)   // an existing key still counts
        XCTAssertEqual(a.cpu, 5)
        XCTAssertEqual(a.stacks.count, 2)
        XCTAssertEqual(a.stacks["s0"], 2)
        XCTAssertEqual(overflow, 6, "stack, leaf and appframe refused for samples 3 and 4")
    }

    func testWaitSamplesAreCountedAndNeverAggregated() {
        var a = Sampler.Aggregate()
        a.addWait(); a.addWait()
        XCTAssertEqual(a.wait, 2)
        XCTAssertEqual(a.cpu, 0)
        XCTAssertTrue(a.stacks.isEmpty)
        XCTAssertEqual(Sampler.stacksLine(a), "main stacks: cpu=0 wait=2")
        XCTAssertNil(Sampler.leafLine(a))
    }

    func testMergeAddsEverything() {
        var a = Sampler.Aggregate(), b = Sampler.Aggregate()
        a.addCPU(sample(["x"]), limits: Sampler.Aggregate.hourLimits); a.addWait()
        b.addCPU(sample(["x"]), limits: Sampler.Aggregate.hourLimits); b.addCPU(sample(["y"]), limits: Sampler.Aggregate.hourLimits)
        a.merge(b)
        XCTAssertEqual(a.cpu, 3); XCTAssertEqual(a.wait, 1)
        XCTAssertEqual(a.stacks["x"], 2); XCTAssertEqual(a.stacks["y"], 1)
    }

    func testTopOrdersByCountThenKey() {
        XCTAssertEqual(Sampler.top(["b": 2, "a": 2, "c": 5, "d": 1], 3).map(\.key), ["c", "a", "b"])
    }

    func testLinesNameSharesAndInnermostFirst() {
        var a = Sampler.Aggregate()
        for _ in 0..<3 { a.addCPU(sample(["inner", "outer"], image: "SwiftUI", app: "Strand.TodayView.body"), limits: Sampler.Aggregate.hourLimits) }
        a.addCPU(sample(["k"], image: "other", detail: "other:libsystem_kernel.dylib", app: "none"), limits: Sampler.Aggregate.hourLimits)
        a.addWait()
        XCTAssertEqual(Sampler.stacksLine(a), "main stacks: cpu=4 wait=1 | 1) 75% (3) inner < outer | 2) 25% (1) k")
        XCTAssertEqual(Sampler.leafLine(a), "main leaf: cpu=4 | 1) 75% (3) inner | 2) 25% (1) k")
        XCTAssertEqual(Sampler.appFrameLine(a), "main appframe: cpu=4 | 1) 75% (3) Strand.TodayView.body | 2) 25% (1) none")
        XCTAssertEqual(Sampler.imagesLine(a, appName: "NOOP", appUUID: "U-1"),
                       "main images: cpu=4 SwiftUI=75%(3) other=25%(1) | other: libsystem_kernel.dylib=1 | uuid NOOP=U-1")
    }

    func testStacksLineKeepsTheTwelveMostFrequent() {
        var a = Sampler.Aggregate()
        for i in 0..<20 { a.addCPU(sample(["s\(i)"]), limits: Sampler.Aggregate.hourLimits) }
        XCTAssertEqual(Sampler.stacksLine(a)?.components(separatedBy: " | ").count, 13)   // header + 12
    }

    func testStoreReportsADayAndTheLast24Hours() {
        let store = Sampler.Store(fileURL: nil)
        for h in 0..<30 { store.recordCPU(sample(["x"]), hour: "2026-11-\(h < 24 ? 26 : 27) \(String(format: "%02d", h % 24))",
                                          day: h < 24 ? "2026-11-26" : "2026-11-27") }
        store.recordWait(hour: "2026-11-27 05", day: "2026-11-27")
        XCTAssertEqual(store.day("2026-11-26").0.cpu, 24)
        XCTAssertEqual(store.day("2026-11-27").0.cpu, 6)
        XCTAssertEqual(store.day("2026-11-27").0.wait, 1)
        XCTAssertEqual(store.lastHours(24).0.cpu, 24, "the 24 newest hour buckets")
        XCTAssertEqual(store.lastHours(3).0.cpu, 3)
    }

    func testStorePersistsAndReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stacks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Sampler.Store(fileURL: url)
        first.recordCPU(sample(["x"]), hour: "2026-11-27 01", day: "2026-11-27")
        first.setApp(name: "NOOP", uuid: "U")
        XCTAssertGreaterThan(first.persist(), 0)
        let second = Sampler.Store(fileURL: url)
        let (day, name, uuid) = second.day("2026-11-27")
        XCTAssertEqual(day.cpu, 1); XCTAssertEqual(name, "NOOP"); XCTAssertEqual(uuid, "U")
    }

    func testCostLinesComeFromTheCounters() {
        typealias C = ForkEnergyCounters.Counter
        let counts = [C.stackSamples.rawValue: 10, C.stackWaitSamples.rawValue: 4, C.stackDropped.rawValue: 1,
                      C.countersFlushes.rawValue: 3, C.countersFlushMs.rawValue: 90]
        let lines = Sampler.costLines(counts)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("main sampler cost: suspended=10 wait=4"))
        XCTAssertTrue(lines[1].hasPrefix("counters cost: flushes=3 flushMs=90"))
        XCTAssertTrue(Sampler.costLines([:]).isEmpty)
    }
}
