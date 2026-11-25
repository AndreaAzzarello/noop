import XCTest
@testable import Strand

// fork-perf: TEMP — pairs with ForkRunLoopMeter.

final class ForkRunLoopMeterTests: XCTestCase {

    private typealias M = ForkRunLoopMeter

    func testBandsSplitAtOneTenAndOneHundredMilliseconds() {
        XCTAssertEqual(M.band(cpuNs: 0), 0)
        XCTAssertEqual(M.band(cpuNs: 999_999), 0)
        XCTAssertEqual(M.band(cpuNs: 1_000_000), 1)
        XCTAssertEqual(M.band(cpuNs: 9_999_999), 1)
        XCTAssertEqual(M.band(cpuNs: 10_000_000), 2)
        XCTAssertEqual(M.band(cpuNs: 99_999_999), 2)
        XCTAssertEqual(M.band(cpuNs: 100_000_000), 3)
    }

    func testRecordCountsForegroundBackgroundBandsAndBleCpu() {
        var core = M.Core()
        core.record(cpuNs: 500_000, wallNs: 600_000, willChange: 1, ble: true, background: false, hour: 9)
        core.record(cpuNs: 5_000_000, wallNs: 9_000_000, willChange: 3, ble: false, background: true, hour: 9)
        core.record(cpuNs: 20_000_000, wallNs: 30_000_000, willChange: 0, ble: true, background: true, hour: 9)
        let drained = core.drain()
        let byCounter = Dictionary(drained.counters.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(byCounter[.rlIterFg], 1)
        XCTAssertEqual(byCounter[.rlIterBg], 2)
        XCTAssertEqual(byCounter[.rlBandLt1], 1)
        XCTAssertEqual(byCounter[.rlBand1to10], 1)
        XCTAssertEqual(byCounter[.rlBand10to100], 1)
        XCTAssertNil(byCounter[.rlBandGt100])
        XCTAssertEqual(byCounter[.rlWillChange], 4)
        XCTAssertEqual(byCounter[.rlCpuMs], 25)       // 25.5 ms, whole ms
        XCTAssertEqual(byCounter[.rlCpuBleMs], 20)    // 20.5 ms
        XCTAssertEqual(byCounter[.rlCpuBgMs], 25)
    }

    func testSubMillisecondCpuCarriesToTheNextDrain() {
        var core = M.Core()
        core.record(cpuNs: 600_000, wallNs: 0, willChange: 0, ble: false, background: false, hour: 0)
        XCTAssertNil(core.drain().counters.first { $0.0 == .rlCpuMs })
        core.record(cpuNs: 600_000, wallNs: 0, willChange: 0, ble: false, background: false, hour: 0)
        XCTAssertEqual(core.drain().counters.first { $0.0 == .rlCpuMs }?.1, 1)   // 1.2 ms in all
    }

    func testOnlyTheFiveSlowestAreKeptAndDrainResetsThem() {
        var core = M.Core()
        for ms in [3, 50, 7, 120, 1, 90, 40, 2] {
            core.record(cpuNs: UInt64(ms) * 1_000_000, wallNs: UInt64(ms) * 2_000_000, willChange: ms, ble: ms == 120,
                        background: true, hour: 4)
        }
        let kept = core.drain().slowest.sorted { $0.cpuNs > $1.cpuNs }.map { Int($0.cpuNs / 1_000_000) }
        XCTAssertEqual(kept, [120, 90, 50, 40, 7])
        XCTAssertTrue(core.drain().slowest.isEmpty)
    }

    func testMergeSlowestKeepsTheDaysFiveSlowestAcrossBatches() {
        func slow(_ ms: UInt64) -> M.Slow { M.Slow(cpuNs: ms * 1_000_000, wallNs: 0, hour: 0, willChange: 0, ble: false) }
        let merged = M.mergeSlowest([slow(100), slow(30), slow(20)], [slow(60), slow(10), slow(200)])
        XCTAssertEqual(merged.map { Int($0.cpuNs / 1_000_000) }, [200, 100, 60, 30, 20])
    }

    func testLinesNameWhatWasMeasured() {
        var counts: [String: Int] = [:]
        XCTAssertNil(M.summaryLine(counts))
        counts[ForkEnergyCounters.Counter.rlIterFg.rawValue] = 10
        counts[ForkEnergyCounters.Counter.rlIterBg.rawValue] = 90
        counts[ForkEnergyCounters.Counter.rlCpuMs.rawValue] = 500
        counts[ForkEnergyCounters.Counter.rlCpuBleMs.rawValue] = 100
        counts[ForkEnergyCounters.Counter.rlBandLt1.rawValue] = 95
        counts[ForkEnergyCounters.Counter.rlBand1to10.rawValue] = 5
        XCTAssertEqual(M.summaryLine(counts),
                       "runloop: iter fg=10 bg=90 cpu=500ms (ble=100ms bg=0ms) bands <1=95 1-10=5 10-100=0 >100=0 willChange=0")
        XCTAssertNil(M.slowestLine([]))
        XCTAssertEqual(M.slowestLine([M.SlowRecord(cpuMs: 120, wallMs: 240, hour: 4, willChange: 2, ble: true)]),
                       "runloop slowest: 1) cpu=120ms wall=240ms hour=4 willChange=2 ble=yes")
    }
}
