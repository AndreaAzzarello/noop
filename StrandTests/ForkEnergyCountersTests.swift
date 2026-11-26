import XCTest
@testable import Strand

// fork-perf: TEMP — tests for the energy audit counters.
final class ForkEnergyCountersTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fork-energy-\(UUID().uuidString).json")
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testBucketIsHourInGivenTimeZone() {
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T10:59:59Z"), timeZone: utc), "2026-11-20 10")
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T11:00:00Z"), timeZone: utc), "2026-11-20 11")
        let rome = TimeZone(identifier: "Europe/Rome")!
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T10:00:00Z"), timeZone: rome), "2026-11-20 11")
    }

    func testCountsAccumulatePerHour() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkObserverWake, at: date("2026-11-20T10:05:00Z"))
        c.note(.hkObserverWake, at: date("2026-11-20T10:50:00Z"))
        c.note(.hkObserverWake, at: date("2026-11-20T11:01:00Z"))
        let snap = c.snapshot()
        XCTAssertEqual(snap["2026-11-20 10"]?["hkObserverWake"], 2)
        XCTAssertEqual(snap["2026-11-20 11"]?["hkObserverWake"], 1)
    }

    func testDurationHelperAddsEventAndMillis() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        let end = date("2026-11-20T10:00:10Z")
        c.note(.writeBack, millis: .writeBackMs, since: end.addingTimeInterval(-2.5), at: end)
        let hour = c.snapshot()["2026-11-20 10"]
        XCTAssertEqual(hour?["writeBack"], 1)
        XCTAssertEqual(hour?["writeBackMs"], 2500)
    }

    func testZeroAmountIsNotRecorded() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkSaveFailed, by: 0)
        XCTAssertTrue(c.snapshot().isEmpty)
    }

    func testFlushPersistsAndNewInstanceReloadsAndMerges() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = date("2026-11-20T10:00:00Z")
        let a = ForkEnergyCounters(fileURL: url, timeZone: utc)
        a.note(.offloadCompleted, by: 3, at: now)
        a.flush(now: now)
        let b = ForkEnergyCounters(fileURL: url, timeZone: utc)
        b.note(.offloadCompleted, at: now)   // noted before the first load, must merge with the file
        XCTAssertEqual(b.snapshot()["2026-11-20 10"]?["offloadCompleted"], 4)
    }

    func testWritesAreThrottled() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = date("2026-11-20T10:00:00Z")
        let c = ForkEnergyCounters(fileURL: url, timeZone: utc)
        c.note(.bgRescore, at: t0)                                  // first note flushes (distantPast)
        c.note(.bgRescore, at: t0.addingTimeInterval(10))           // inside the interval: memory only
        let onDisk = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk?["2026-11-20 10"]?["bgRescore"], 1)
        c.flush(now: t0.addingTimeInterval(11))
        let after = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(after?["2026-11-20 10"]?["bgRescore"], 2)
    }

    func testOldHoursArePruned() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ForkEnergyCounters(fileURL: url, timeZone: utc)
        let start = date("2026-01-01T00:00:00Z")
        for h in 0..<(ForkEnergyCounters.keptHours + 5) {
            c.note(.widgetReload, at: start.addingTimeInterval(Double(h) * 3600))
        }
        c.flush(now: start.addingTimeInterval(1_000_000))
        let onDisk = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk?.count, ForkEnergyCounters.keptHours)
        XCTAssertNil(onDisk?["2026-01-01 00"])
    }

    func testReportHasDayTotalsAndNoUnknownNames() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkVitalsWritten, by: 56, at: date("2026-11-20T10:00:00Z"))
        c.note(.hkVitalsWritten, by: 4, at: date("2026-11-20T11:00:00Z"))
        let text = c.report()
        XCTAssertTrue(text.contains("2026-11-20 total: hkVitalsWritten=60"))
        XCTAssertTrue(text.contains("2026-11-20 10h: hkVitalsWritten=56"))
    }

    func testEmptyReport() {
        XCTAssertTrue(ForkEnergyCounters(fileURL: nil, timeZone: utc).report().contains("nothing recorded"))
    }

    // MARK: MetricKit days

    func testMetricKitDayMergeReplacesSameDayAndBounds() {
        var days: [ForkMetricKitDay] = []
        for i in 1...20 {
            days = ForkMetricKitDays.merged(days, with: ForkMetricKitDay(day: String(format: "2026-11-%02d", i), appVersion: nil))
        }
        XCTAssertEqual(days.count, ForkMetricKitDays.keptDays)
        XCTAssertEqual(days.first?.day, "2026-11-07")
        var updated = ForkMetricKitDay(day: "2026-11-20", appVersion: "1")
        updated.cpuSec = 12
        days = ForkMetricKitDays.merged(days, with: updated)
        XCTAssertEqual(days.count, ForkMetricKitDays.keptDays)
        XCTAssertEqual(days.last?.cpuSec, 12)
    }

    func testMetricKitDayRoundTripAndLine() throws {
        var d = ForkMetricKitDay(day: "2026-11-19", appVersion: "2.0.9")
        d.backgroundSec = 12_540; d.cpuSec = 300; d.exits = ["cpuLimit": 1]
        let back = try JSONDecoder().decode(ForkMetricKitDay.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        let line = d.line()
        XCTAssertTrue(line.contains("bg=12540s"))
        XCTAssertTrue(line.contains("exits[cpuLimit=1]"))
        XCTAssertTrue(line.contains("fg=?s"))
    }

    func testCPUHelperIsMonotonicAndBooksToThePhaseCounter() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        let start = ForkEnergyCounters.cpuNowMillis()
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThanOrEqual(ForkEnergyCounters.cpuNowMillis(), start)
        let now = date("2026-11-21T09:00:00Z")
        c.noteCPU(.cpuRescoreMs, since: start, at: now)
        c.note(.nightCardTask, at: now)
        let hour = c.snapshot()["2026-11-21 09"]
        XCTAssertNotNil(hour?["nightCardTask"])
        XCTAssertTrue(ForkEnergyCounters.Counter.allCases.contains(.cpuProcessMs))
    }

    // MARK: Per-source counters (round 3)

    func testRescoreTriggersMapToTheirOwnCounters() {
        typealias C = ForkEnergyCounters
        XCTAssertEqual(C.rescoreCounters(trigger: "idle").runs, .rescoreIdle)
        XCTAssertEqual(C.rescoreCounters(trigger: "post-offload").ms, .rescorePostOffloadMs)
        XCTAssertEqual(C.rescoreCounters(trigger: "resume-gated").runs, .rescoreResume)
        XCTAssertEqual(C.rescoreCounters(trigger: "resume-forced").ms, .rescoreResumeMs)
        XCTAssertEqual(C.rescoreCounters(trigger: "forced").runs, .rescoreForced)
        XCTAssertEqual(C.rescoreCounters(trigger: "sleep-wear-history-repair").runs, .rescoreForced)
    }

    func testBLEFrameCountsAllAndDataFrames() {
        let c = ForkEnergyCounters.shared
        c.reset()
        c.noteBLEFrame(isData: false)
        c.noteBLEFrame(isData: true)
        c.noteBLEFrame(isData: true)
        let total = c.snapshot().values.reduce(into: [String: Int]()) { acc, hour in
            for (k, v) in hour { acc[k, default: 0] += v }
        }
        XCTAssertEqual(total["bleFrames"], 3)
        XCTAssertEqual(total["bleRawFrames"], 2)
        c.reset()
    }

    func testLogLineCountsEveryLineAndCarriesSubMillisecondTime() {
        let c = ForkEnergyCounters.shared
        c.reset()
        for _ in 0..<3 { c.noteLogLine(sinceNanos: DispatchTime.now().uptimeNanoseconds) }
        let total = c.snapshot().values.reduce(into: [String: Int]()) { acc, hour in
            for (k, v) in hour { acc[k, default: 0] += v }
        }
        XCTAssertEqual(total["logLines"], 3)
        XCTAssertLessThan(total["logAppendMs", default: 0], 5, "instant lines must not book whole milliseconds")
        c.reset()
    }

    func testNewCountersAppearInTheReportAndTheWorkersBucketIsRenamed() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        let at = date("2026-11-21T09:00:00Z")
        for counter in [ForkEnergyCounters.Counter.widgetReloadLive, .widgetReloadFork, .widgetReloadCoach,
                        .widgetPublishPostOffload, .rescoreDaysCached, .hrSamples, .liveWillChange, .uiBodyBg] {
            c.note(counter, at: at)
        }
        let report = c.report()
        for name in ["widgetReloadLive", "widgetReloadFork", "widgetReloadCoach", "widgetPublishPostOffload",
                     "rescoreDaysCached", "hrSamples", "liveWillChange", "uiBodyBg"] {
            XCTAssertTrue(report.contains("\(name)=1"), name)
        }
        XCTAssertEqual(ForkEnergyCounters.bucket(threadName: "x.cooperative", isMain: false), .cpuThrWorkersMs)
        XCTAssertNil(ForkEnergyCounters.Counter(rawValue: "cpuThrCoopMs"))
    }

    // MARK: Re-score phases

    func testRescorePhasesBookEachBucketOnceAndThreadMicrosecondsAsMillis() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        var tally = ForkEnergyCounters.RescorePhaseTally()
        tally.keyMs = 40; tally.prepMs = 900; tally.scoreMs = 300; tally.scoreThreadUs = 250_900
        tally.restMs = 60; tally.paceMs = 1_200
        let now = date("2026-11-24T09:00:00Z")
        c.noteRescorePhases(preMs: 75, tally, at: now)
        let hour = c.snapshot()["2026-11-24 09"]
        XCTAssertEqual(hour?["rescorePreMs"], 75)
        XCTAssertEqual(hour?["rescoreKeyMs"], 40)
        XCTAssertEqual(hour?["rescorePrepMs"], 900)
        XCTAssertEqual(hour?["rescoreScoreMs"], 300)
        XCTAssertEqual(hour?["rescoreScoreThrMs"], 250)
        XCTAssertEqual(hour?["rescoreLoopRestMs"], 60)
        XCTAssertEqual(hour?["rescorePaceMs"], 1_200)
    }

    func testRescoreLapsAreNonNegativeAndThreadClockAdvances() {
        var tally = ForkEnergyCounters.RescorePhaseTally()
        XCTAssertGreaterThanOrEqual(tally.lap(), 0)
        let t0 = ForkEnergyCounters.threadCPUNanos()
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThan(ForkEnergyCounters.threadCPUNanos(), t0)
        XCTAssertGreaterThanOrEqual(tally.lap(), 0)
    }

    // MARK: Main-thread call sites

    private func ms(_ n: UInt64) -> UInt64 { n * 1_000_000 }

    private func drained(_ meter: inout ForkMainCPU.Meter) -> [ForkMainCPU.Point: Int] {
        Dictionary(uniqueKeysWithValues: meter.drainMillis().map { ($0.point, $0.ms) })
    }

    func testNestedPointsBookExclusiveTimeSoTheyAddUp() {
        var m = ForkMainCPU.Meter()
        let notify = m.begin(.bleNotify, at: 0)
        let router = m.begin(.bleRouter, at: ms(2))          // 2 ms of the handler's own work first
        let log = m.begin(.log, at: ms(3))
        m.end(log, at: ms(4))                                  // log: 1 ms
        m.end(router, at: ms(10))                              // router: 8 ms inclusive, 7 exclusive
        m.end(notify, at: ms(12))                              // notify: 12 inclusive, 12 - 8 = 4 exclusive
        let out = drained(&m)
        XCTAssertEqual(out[.log], 1)
        XCTAssertEqual(out[.bleRouter], 7)
        XCTAssertEqual(out[.bleNotify], 4)
        XCTAssertEqual(out.values.reduce(0, +), 12)            // = the outermost point's elapsed time
        XCTAssertTrue(m.isIdle)
    }

    func testAnEndIsIdempotentAndALateTokenNeverClosesAnotherPoint() {
        var m = ForkMainCPU.Meter()
        let first = m.begin(.offload, at: 0)
        m.end(first, at: ms(5))
        let second = m.begin(.sinks, at: ms(6))               // opened after the first one closed
        m.end(first, at: ms(9))                                // a late `end` of the first (after an await): no effect
        XCTAssertFalse(m.isIdle)
        m.end(second, at: ms(11))
        let out = drained(&m)
        XCTAssertEqual(out[.offload], 5)
        XCTAssertEqual(out[.sinks], 5)
    }

    func testAnOuterEndClosesAnInnerPointThatWasLeftOpen() {
        var m = ForkMainCPU.Meter()
        let outer = m.begin(.bleNotify, at: 0)
        _ = m.begin(.bleCollector, at: ms(1))                  // never ended
        m.end(outer, at: ms(6))
        XCTAssertTrue(m.isIdle)
        let out = drained(&m)
        XCTAssertEqual(out[.bleCollector], 5)
        XCTAssertEqual(out[.bleNotify], 1)
    }

    func testSubMillisecondRemaindersCarryToTheNextDrain() {
        var m = ForkMainCPU.Meter()
        for _ in 0..<4 {
            let t = m.begin(.ingestHR, at: 0)
            m.end(t, at: 400_000)                              // 0.4 ms each
        }
        XCTAssertEqual(drained(&m)[.ingestHR], 1)              // 1.6 ms booked as 1 ms, 0.6 ms kept
        let t = m.begin(.ingestHR, at: 0)
        m.end(t, at: 500_000)
        XCTAssertEqual(drained(&m)[.ingestHR], 1)              // 0.6 + 0.5 = 1.1 ms
    }

    func testNothingBookedBeforeAMillisecondAccumulates() {
        var m = ForkMainCPU.Meter()
        let t = m.begin(.log, at: 0)
        m.end(t, at: 900_000)
        XCTAssertTrue(m.drainMillis().isEmpty)
    }

    func testFramesAreClassifiedByTheTypeByteOfTheirFamily() {
        func frame(type: UInt8, at index: Int, count: Int = 12) -> [UInt8] {
            var f = [UInt8](repeating: 0, count: count); f[index] = type; return f
        }
        typealias C = ForkMainCPU.FrameClass
        XCTAssertEqual(C.classify(frame: frame(type: 43, at: 4), family: .whoop4), .raw43)
        XCTAssertEqual(C.classify(frame: frame(type: 40, at: 4), family: .whoop4), .realtime40)
        for offload: UInt8 in [47, 48, 49, 50, 56] {
            XCTAssertEqual(C.classify(frame: frame(type: offload, at: 4), family: .whoop4), .offload)
            XCTAssertEqual(C.classify(frame: frame(type: offload, at: 8), family: .whoop5), .offload)
        }
        XCTAssertEqual(C.classify(frame: frame(type: 43, at: 8), family: .whoop5), .raw43)
        // The 4.0 offset is not read on a 5/MG, and vice versa.
        XCTAssertEqual(C.classify(frame: frame(type: 43, at: 4), family: .whoop5), .other)
        XCTAssertEqual(C.classify(frame: frame(type: 43, at: 8), family: .whoop4), .other)
        XCTAssertEqual(C.classify(frame: [1, 2, 3], family: .whoop5), .other)
        XCTAssertEqual(Set(C.allCases.map { $0.counters.count }).count, C.allCases.count)
        XCTAssertEqual(Set(C.allCases.map { $0.counters.bytes }).count, C.allCases.count)
    }

    func testEveryPointHasItsOwnCounter() {
        let counters = ForkMainCPU.Point.allCases.map(\.counter)
        XCTAssertEqual(Set(counters).count, counters.count)
    }

    func testMeterCountsCallsPerPointAndOnlyOffersCallCountersForTheNewOnes() {
        var meter = ForkMainCPU.Meter()
        let a = meter.begin(.chunkAck, at: 0); meter.end(a, at: 1_000_000)
        let b = meter.begin(.chunkAck, at: 2_000_000); meter.end(b, at: 3_000_000)
        let c = meter.begin(.bleNotify, at: 4_000_000); meter.end(c, at: 5_000_000)
        let calls = meter.drainCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.counter, .chunkAckCalls)
        XCTAssertEqual(calls.first?.calls, 2)
        XCTAssertTrue(meter.drainCalls().isEmpty)
        let counters = ForkMainCPU.Point.allCases.compactMap(\.callsCounter)
        XCTAssertEqual(Set(counters).count, counters.count)
    }

    func testOnlyTheLiveActivityPointsAreNotBLE() {
        XCTAssertEqual(ForkMainCPU.Point.allCases.filter { !$0.isBLE }, [.liveActivity, .liveActivityList])
        XCTAssertEqual(Set(ForkMainCPU.Point.allCases.map(\.label)).count, ForkMainCPU.Point.allCases.count)
    }

    func testMainSplitLineNamesWhatIsAttributedAndWhatIsNot() {
        var counts: [String: Int] = [ForkEnergyCounters.Counter.cpuThrMainMs.rawValue: 1_000]
        XCTAssertNil(ForkEnergyCounters.mainSplitLine(counts))                    // nothing booked by a call site
        counts[ForkEnergyCounters.Counter.mainBleNotifyMs.rawValue] = 300
        counts[ForkEnergyCounters.Counter.mainBleRouterMs.rawValue] = 100
        counts[ForkEnergyCounters.Counter.mainLogMs.rawValue] = 50
        XCTAssertEqual(ForkEnergyCounters.mainSplitLine(counts),
                       "main split: main=1000ms attributed=450ms (notify=300 router=100 log=50) unattributed=550ms (55%)")
        counts[ForkEnergyCounters.Counter.mainSinksMs.rawValue] = 900             // more than the sampled main: floors at 0
        XCTAssertTrue(ForkEnergyCounters.mainSplitLine(counts)?.hasSuffix("unattributed=0ms (0%)") == true)
        XCTAssertNil(ForkEnergyCounters.mainSplitLine([ForkEnergyCounters.Counter.mainLogMs.rawValue: 5]))  // no main sample
    }

    func testReportCarriesTheSplitLineBesideTheHour() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        let now = date("2026-11-24T09:00:00Z")
        c.note(.cpuThrMainMs, by: 500, at: now)
        c.note(.mainBleNotifyMs, by: 200, at: now)
        XCTAssertTrue(c.report().contains("main split: main=500ms attributed=200ms (notify=200) unattributed=300ms (60%)"))
    }

    // MARK: - Real main thread against "the first listed thread"

    func testAttributeBooksTheCapturedMainThreadEvenWhenItIsNotListedFirst() {
        typealias C = ForkEnergyCounters
        let slices = [
            C.ThreadSlice(id: 1, name: "", cpuMs: 900, isMain: true),                    // listed first, not the real main
            C.ThreadSlice(id: 2, name: "", cpuMs: 100, isMain: false, isRealMain: true)]
        let split = C.attribute(slices: slices, previous: [:], processDelta: 1_000)
        XCTAssertEqual(split.byBucket[.cpuThrMainMs], 900)
        XCTAssertEqual(split.byBucket[.cpuThrMainRealMs], 100)
    }

    func testMainCheckSaysUnknownMismatchOrNothing() {
        typealias C = ForkEnergyCounters
        let agree = [C.ThreadSlice(id: 1, name: "", cpuMs: 1, isMain: true, isRealMain: true)]
        let differ = [C.ThreadSlice(id: 1, name: "", cpuMs: 1, isMain: true),
                      C.ThreadSlice(id: 2, name: "", cpuMs: 1, isMain: false, isRealMain: true)]
        XCTAssertEqual(C.mainCheck(slices: agree, captured: false), .mainThreadUnknown)
        XCTAssertNil(C.mainCheck(slices: agree, captured: true))
        XCTAssertEqual(C.mainCheck(slices: differ, captured: true), .mainThreadMismatch)
    }

    func testMainCheckLineComparesTheTwoFigures() {
        var counts: [String: Int] = [:]
        XCTAssertNil(ForkEnergyCounters.mainCheckLine(counts))
        counts[ForkEnergyCounters.Counter.cpuThrMainMs.rawValue] = 6_900
        counts[ForkEnergyCounters.Counter.cpuThrMainRealMs.rawValue] = 120
        counts[ForkEnergyCounters.Counter.mainThreadMismatch.rawValue] = 288
        XCTAssertEqual(ForkEnergyCounters.mainCheckLine(counts),
                       "main check: first=6900ms real=120ms mismatch=288 unknown=0")
    }

    func testTheRealMainThreadIsCapturedOnTheMainThreadAndFoundInTheLiveList() {
        let done = expectation(description: "main")
        DispatchQueue.main.async {
            ForkEnergyCounters.captureMainThreadIfNeeded()
            let slices = ForkEnergyCounters.threadSlices()
            XCTAssertEqual(slices.filter(\.isRealMain).count, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
