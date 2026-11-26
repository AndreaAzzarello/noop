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
    // MARK: Conditions of the slow iterations

    private func counters(_ d: (counters: [(ForkEnergyCounters.Counter, Int)], slowest: [M.Slow])) -> [ForkEnergyCounters.Counter: Int] {
        Dictionary(d.counters.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
    }

    func testOnlyIterationsOver100MsAreBookedByConditionAndTab() {
        var core = M.Core()
        let bgCharging = M.CondKind.bg.bit | M.CondKind.charging.bit
        core.record(cpuNs: 150_000_000, wallNs: 0, willChange: 0, ble: true, background: true, hour: 3,
                    conditions: bgCharging, ran: 0, tab: 2)
        core.record(cpuNs: 50_000_000, wallNs: 0, willChange: 0, ble: true, background: true, hour: 3,
                    conditions: M.CondKind.locked.bit, ran: 1, tab: 2)   // under the threshold: not labelled
        let c = counters(core.drain())
        XCTAssertEqual(c[.rlSlowMs], 150)
        XCTAssertEqual(c[.rlSlowNoPoint], 1)
        XCTAssertEqual(c[.rlSlowBg], 1)
        XCTAssertEqual(c[.rlSlowBgMs], 150)
        XCTAssertEqual(c[.rlSlowCharging], 1)
        XCTAssertNil(c[.rlSlowLocked])
        XCTAssertEqual(c[.rlSlowTab2], 150)
        XCTAssertNil(c[.rlSlowTab0])
    }

    func testRanPointsKeepTheSlowIterationOutOfNoPoint() {
        var core = M.Core()
        core.record(cpuNs: 120_000_000, wallNs: 0, willChange: 0, ble: true, background: false, hour: 0,
                    conditions: 0, ran: 1 << UInt32(ForkMainCPU.Point.chunkAck.rawValue), tab: -1)
        let c = counters(core.drain())
        XCTAssertNil(c[.rlSlowNoPoint])
        XCTAssertEqual(c[.rlSlowTabNone], 120)
    }

    func testSlowCpuRemainderCarriesToTheNextDrain() {
        var core = M.Core()
        core.record(cpuNs: 100_600_000, wallNs: 0, willChange: 0, ble: false, background: false, hour: 0, conditions: M.CondKind.bg.bit)
        XCTAssertEqual(counters(core.drain())[.rlSlowBgMs], 100)
        core.record(cpuNs: 100_600_000, wallNs: 0, willChange: 0, ble: false, background: false, hour: 0, conditions: M.CondKind.bg.bit)
        XCTAssertEqual(counters(core.drain())[.rlSlowBgMs], 101)   // 0.6 + 100.6 ms
    }

    func testExposureTicksCountConditionsAndTabs() {
        var core = M.Core()
        core.record(cpuNs: 1_000, wallNs: 0, willChange: 0, ble: false, background: false, hour: 0)
        core.expose(conditions: M.CondKind.bg.bit | M.CondKind.wifi.bit, tab: 1)
        core.expose(conditions: M.CondKind.bg.bit, tab: 9)
        let c = counters(core.drain())
        XCTAssertEqual(c[.rlExpTicks], 2)
        XCTAssertEqual(c[.rlExpBg], 2)
        XCTAssertEqual(c[.rlExpWifi], 1)
        XCTAssertEqual(c[.rlExpTab1], 1)
        XCTAssertEqual(c[.rlExpTabNone], 1)
        XCTAssertNil(counters(core.drain())[.rlExpTicks])
    }

    func testSlowestLineNamesConditionsRanPointsAndTabAndOldRecordsStillDecode() {
        let cond = Int(M.CondKind.bg.bit | M.CondKind.locked.bit)
        let ran = 1 << ForkMainCPU.Point.bleStdHR.rawValue | 1 << ForkMainCPU.Point.chunkAck.rawValue
        let line = M.slowestLine([M.SlowRecord(cpuMs: 190, wallMs: 200, hour: 4, willChange: 1, ble: true,
                                               cond: cond, ran: ran, tab: 0)])
        XCTAssertEqual(line, "runloop slowest: 1) cpu=190ms wall=200ms hour=4 willChange=1 ble=yes cond=bg,locked ran=stdHR,chunkAck tab=0")
        let old = #"{"cpuMs":120,"wallMs":240,"hour":4,"willChange":2,"ble":true}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(M.SlowRecord.self, from: old)
        XCTAssertEqual(decoded, M.SlowRecord(cpuMs: 120, wallMs: 240, hour: 4, willChange: 2, ble: true))
        XCTAssertNil(decoded?.cond)
    }

    func testSlowByConditionLine() {
        XCTAssertNil(M.slowByConditionLine([:]))
        var counts: [String: Int] = [:]
        counts[ForkEnergyCounters.Counter.rlSlowMs.rawValue] = 900
        counts[ForkEnergyCounters.Counter.rlSlowBg.rawValue] = 5
        counts[ForkEnergyCounters.Counter.rlSlowBgMs.rawValue] = 800
        counts[ForkEnergyCounters.Counter.rlSlowTab0.rawValue] = 700
        counts[ForkEnergyCounters.Counter.rlExpTicks.rawValue] = 60
        counts[ForkEnergyCounters.Counter.rlExpBg.rawValue] = 40
        let line = M.slowByConditionLine(counts) ?? ""
        XCTAssertTrue(line.hasPrefix("runloop slow by condition: cpu=900ms noPoint=0 | bg=5/800 locked=0/0"))
        XCTAssertTrue(line.contains("tab0=700 tab1=0"))
        XCTAssertTrue(line.hasSuffix("exposure ticks=60 bg=40 locked=0 charging=0 lowPower=0 offload=0 liveActivity=0 refresh=0 wifi=0 cellular=0 tab0=0 tab1=0 tab2=0 tab3=0 tab4=0 tab?=0"))
    }
}
