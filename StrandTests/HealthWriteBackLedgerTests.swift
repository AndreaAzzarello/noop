import XCTest
import StrandImport
@testable import Strand

/// The write-back ledger: unchanged keys are skipped, changed or new ones are rewritten, and every failure or
/// expiry falls back to rewriting the whole section.
final class HealthWriteBackLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let build = "2.0.9+1"
    private let scope = "strap-A"

    private func desired(_ pairs: [(String, UInt64)]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    private func store(_ url: URL? = nil, build: String? = nil) -> HealthWriteBackLedgerStore {
        HealthWriteBackLedgerStore(fileURL: url, build: build ?? self.build)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
    }

    // MARK: plan

    func testEmptyLedgerRewritesEverything() {
        let s = store()
        let plan = s.plan(.vitals, desired: desired([("a", 1), ("b", 2)]), scope: scope, now: t0, enabled: true)
        XCTAssertTrue(plan.fullRewrite)
        XCTAssertEqual(plan.dirty, ["a", "b"])
    }

    func testUnchangedSkipsEverything() {
        let s = store()
        let d = desired([("a", 1), ("b", 2)])
        s.commit(s.plan(.vitals, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let again = s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(900), enabled: true)
        XCTAssertFalse(again.fullRewrite)
        XCTAssertTrue(again.dirty.isEmpty)
        XCTAssertEqual(again.unchangedCount, 2)
    }

    func testChangedKeyOnlyIsRewritten() {
        let s = store()
        s.commit(s.plan(.vitals, desired: desired([("a", 1), ("b", 2)]), scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let p = s.plan(.vitals, desired: desired([("a", 1), ("b", 99)]), scope: scope, now: t0.addingTimeInterval(60), enabled: true)
        XCTAssertEqual(p.dirty, ["b"])
        XCTAssertEqual(p.unchangedCount, 1)
    }

    func testNewKeyIsRewritten() {
        let s = store()
        s.commit(s.plan(.sleep, desired: desired([("a", 1)]), scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let p = s.plan(.sleep, desired: desired([("a", 1), ("c", 3)]), scope: scope, now: t0.addingTimeInterval(60), enabled: true)
        XCTAssertEqual(p.dirty, ["c"])
    }

    func testRemovedKeyIsReportedAndDroppedOnCommit() {
        let s = store()
        s.commit(s.plan(.workouts, desired: desired([("a", 1), ("b", 2)]), scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let p = s.plan(.workouts, desired: desired([("a", 1)]), scope: scope, now: t0.addingTimeInterval(60), enabled: true)
        XCTAssertEqual(p.removed, ["b"])
        XCTAssertTrue(p.dirty.isEmpty)
        s.commit(p, now: t0.addingTimeInterval(60), enabled: true)
        XCTAssertEqual(s.snapshot().sections["workouts"]?.fingerprints.keys.sorted(), ["a"])
    }

    func testTTLForcesFullRewrite() {
        let s = store()
        let d = desired([("a", 1)])
        s.commit(s.plan(.vitals, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let justUnder = s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(24 * 3600 - 1), enabled: true)
        XCTAssertFalse(justUnder.fullRewrite)
        let atTTL = s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(24 * 3600), enabled: true)
        XCTAssertTrue(atTTL.fullRewrite)
        XCTAssertEqual(atTTL.dirty, ["a"])
    }

    func testIncrementalCommitDoesNotExtendTheTTL() {
        let s = store()
        s.commit(s.plan(.vitals, desired: desired([("a", 1)]), scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let later = t0.addingTimeInterval(20 * 3600)
        let inc = s.plan(.vitals, desired: desired([("a", 2)]), scope: scope, now: later, enabled: true)
        XCTAssertFalse(inc.fullRewrite)
        s.commit(inc, now: later, enabled: true)
        let after = s.plan(.vitals, desired: desired([("a", 2)]), scope: scope, now: t0.addingTimeInterval(25 * 3600), enabled: true)
        XCTAssertTrue(after.fullRewrite, "the full-rewrite clock runs from the last FULL rewrite")
    }

    func testClockMovingBackwardsFallsBackToFullRewrite() {
        let s = store()
        let d = desired([("a", 1)])
        s.commit(s.plan(.vitals, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        XCTAssertTrue(s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(-60), enabled: true).fullRewrite)
    }

    func testBuildChangeForcesFullRewrite() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let a = store(url, build: "2.0.9+1")
        let d = desired([("a", 1)])
        a.commit(a.plan(.heartRate, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let b = store(url, build: "2.0.9+2")
        XCTAssertTrue(b.plan(.heartRate, desired: d, scope: scope, now: t0.addingTimeInterval(60), enabled: true).fullRewrite)
        let same = store(url, build: "2.0.9+1")
        XCTAssertFalse(same.plan(.heartRate, desired: d, scope: scope, now: t0.addingTimeInterval(60), enabled: true).fullRewrite)
    }

    func testScopeChangeForcesFullRewrite() {
        let s = store()
        let d = desired([("a", 1)])
        s.commit(s.plan(.heartRate, desired: d, scope: "strap-A", now: t0, enabled: true), now: t0, enabled: true)
        XCTAssertTrue(s.plan(.heartRate, desired: d, scope: "strap-B", now: t0.addingTimeInterval(60), enabled: true).fullRewrite)
    }

    // MARK: failure and switch

    func testPlanAloneNeverMovesTheLedger() {
        let s = store()
        _ = s.plan(.vitals, desired: desired([("a", 1)]), scope: scope, now: t0, enabled: true)
        XCTAssertTrue(s.snapshot().sections.isEmpty, "only commit, after a successful save, may move it")
    }

    func testFailureInvalidatesTheSectionOnly() {
        let s = store()
        let d = desired([("a", 1)])
        for section in [HealthWriteBackLedger.Section.vitals, .sleep] {
            s.commit(s.plan(section, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        }
        s.recordFailure(.vitals)
        XCTAssertTrue(s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(60), enabled: true).fullRewrite)
        XCTAssertFalse(s.plan(.sleep, desired: d, scope: scope, now: t0.addingTimeInterval(60), enabled: true).fullRewrite)
    }

    func testFailureIsSurfacedOnlyFromTheThirdInARow() {
        let s = store()
        XCTAssertFalse(s.recordFailure(.heartRate))
        XCTAssertFalse(s.recordFailure(.heartRate))
        XCTAssertTrue(s.recordFailure(.heartRate))
        s.recordSuccess(.heartRate)
        XCTAssertFalse(s.recordFailure(.heartRate), "a success resets the run")
    }

    func testCommitResetsTheFailureRun() {
        let s = store()
        s.recordFailure(.sleep); s.recordFailure(.sleep)
        s.commit(s.plan(.sleep, desired: desired([("a", 1)]), scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        XCTAssertFalse(s.recordFailure(.sleep))
    }

    func testSwitchOffRewritesEverythingAndClearsTheLedger() {
        let s = store()
        let d = desired([("a", 1)])
        s.commit(s.plan(.vitals, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let off = s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(60), enabled: false)
        XCTAssertTrue(off.fullRewrite)
        XCTAssertEqual(off.dirty, ["a"])
        s.commit(off, now: t0.addingTimeInterval(60), enabled: false)
        XCTAssertTrue(s.snapshot().sections.isEmpty, "off: nothing recorded, and the old entry is gone")
        // Switching back on must not trust anything from before.
        XCTAssertTrue(s.plan(.vitals, desired: d, scope: scope, now: t0.addingTimeInterval(120), enabled: true).fullRewrite)
    }

    // MARK: persistence

    func testLedgerSurvivesARelaunch() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let big: UInt64 = 0xffff_ffff_ffff_fff1   // would not survive a JSON number
        let a = store(url)
        a.commit(a.plan(.vitals, desired: ["k": big], scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        let b = store(url)
        let p = b.plan(.vitals, desired: ["k": big], scope: scope, now: t0.addingTimeInterval(60), enabled: true)
        XCTAssertFalse(p.fullRewrite)
        XCTAssertTrue(p.dirty.isEmpty)
    }

    // MARK: no duplicates

    /// Replays passes the way the bridge does (delete the dirty keys, save them) against a model of Health, and
    /// checks that a key never holds more than one sample and that nothing but changed keys is touched.
    func testSimulatedHealthNeverHoldsADuplicate() {
        let s = store()
        var health: [String: [UInt64]] = [:]   // key → samples present
        var touched: [[String]] = []
        func pass(_ d: [String: UInt64], at now: Date, failDelete: Set<String> = []) {
            let plan = s.plan(.vitals, desired: d, scope: scope, now: now, enabled: true)
            var failed = false
            var touchedNow: [String] = []
            for key in plan.dirty.sorted() {
                if failDelete.contains(key) { failed = true; continue }   // delete threw: skip the save too
                health[key] = []                                            // delete
                health[key, default: []].append(d[key]!)                    // save
                touchedNow.append(key)
            }
            touched.append(touchedNow)
            if failed { s.recordFailure(.vitals) } else { s.commit(plan, now: now, enabled: true) }
        }
        pass(["a": 1, "b": 2], at: t0)
        pass(["a": 1, "b": 2], at: t0.addingTimeInterval(900))
        pass(["a": 1, "b": 3], at: t0.addingTimeInterval(1800))
        pass(["a": 5, "b": 3, "c": 7], at: t0.addingTimeInterval(2700), failDelete: ["a"])
        pass(["a": 5, "b": 3, "c": 7], at: t0.addingTimeInterval(3600))   // the failed section is rewritten whole
        pass(["a": 5, "b": 3, "c": 7], at: t0.addingTimeInterval(4500))
        XCTAssertEqual(touched[0], ["a", "b"])
        XCTAssertEqual(touched[1], [])
        XCTAssertEqual(touched[2], ["b"])
        XCTAssertEqual(touched[3], ["c"], "a's delete failed: no save for a, the others proceed")
        XCTAssertEqual(touched[4], ["a", "b", "c"], "after a failure the whole section is rewritten")
        XCTAssertEqual(touched[5], [])
        for (key, samples) in health { XCTAssertEqual(samples.count, 1, "\(key) holds exactly one sample") }
        XCTAssertEqual(health["a"], [5])
    }

    // MARK: fingerprints and keys

    func testFingerprintIsDeterministicAndSensitive() {
        let a = HealthWriteBackLedgerKeys.vital(value: 52.5, at: t0)
        XCTAssertEqual(a, HealthWriteBackLedgerKeys.vital(value: 52.5, at: t0))
        XCTAssertNotEqual(a, HealthWriteBackLedgerKeys.vital(value: 52.6, at: t0))
        XCTAssertNotEqual(a, HealthWriteBackLedgerKeys.vital(value: 52.5, at: t0.addingTimeInterval(1)))
        XCTAssertNotEqual(a, HealthWriteBackLedgerKeys.retracted)
    }

    func testFnvKnownVector() {
        // FNV-1a 64 of "a" is af63dc4c8601ec8c; the builder appends a 0x1f separator, so hash the raw bytes here.
        var h: UInt64 = 0xcbf29ce484222325
        h = (h ^ 0x61) &* 0x100000001b3
        XCTAssertEqual(h, 0xaf63dc4c8601ec8c)
    }

    func testSleepFingerprintTracksSpanAndStages() {
        func entry(end: Int, kind: HealthWriteback.StageKind = .deep) -> HealthWriteback.MergedSleepEntry {
            .init(keyStartTs: 100, spanStart: 100, spanEnd: end,
                  intervals: [.init(start: 100, end: end, kind: kind)], allKeyStartTs: [100])
        }
        let base = HealthWriteBackLedgerKeys.sleep(entry(end: 200))
        XCTAssertEqual(base, HealthWriteBackLedgerKeys.sleep(entry(end: 200)))
        XCTAssertNotEqual(base, HealthWriteBackLedgerKeys.sleep(entry(end: 201)))
        XCTAssertNotEqual(base, HealthWriteBackLedgerKeys.sleep(entry(end: 200, kind: .rem)))
        let merged = HealthWriteback.MergedSleepEntry(keyStartTs: 100, spanStart: 100, spanEnd: 200,
            intervals: [.init(start: 100, end: 200, kind: .deep)], allKeyStartTs: [100, 150])
        XCTAssertNotEqual(base, HealthWriteBackLedgerKeys.sleep(merged), "absorbing a fragment must rewrite the night")
    }

    func testHourBlocksOnlyTheTouchedHourChanges() {
        let h = 3600
        let base = 500 * h
        var buckets: [(ts: Int, bpm: Double)] = (0..<120).map { (ts: base + $0 * 60, bpm: 60 + Double($0 % 5)) }
        let before = HealthWriteBackLedgerKeys.hourBlocks(buckets)
        XCTAssertEqual(Set(before.keys), [500, 501])
        buckets.append((ts: base + 120 * 60, bpm: 70))   // a new minute lands in hour 502
        let after = HealthWriteBackLedgerKeys.hourBlocks(buckets)
        XCTAssertEqual(after[500], before[500])
        XCTAssertEqual(after[501], before[501])
        XCTAssertNotNil(after[502])
        buckets[70] = (ts: buckets[70].ts, bpm: 99)   // a value inside hour 501 (indexes 60...119) changes
        let edited = HealthWriteBackLedgerKeys.hourBlocks(buckets)
        XCTAssertEqual(edited[500], before[500])
        XCTAssertNotEqual(edited[501], before[501])
    }

    func testHourBlockFingerprintIsOrderIndependent() {
        let a: [(ts: Int, bpm: Double)] = [(3600, 60), (3660, 61)]
        let b: [(ts: Int, bpm: Double)] = [(3660, 61), (3600, 60)]
        XCTAssertEqual(HealthWriteBackLedgerKeys.hourBlocks(a), HealthWriteBackLedgerKeys.hourBlocks(b))
    }

    func testRunsFoldConsecutiveHours() {
        XCTAssertEqual(HealthWriteBackLedgerKeys.runs(of: [5, 3, 4, 9, 11, 10, 3]), [3...5, 9...11])
        XCTAssertEqual(HealthWriteBackLedgerKeys.runs(of: []), [])
    }

    func testDeleteRangeEndsBeforeTheNextHour() {
        let r = HealthWriteBackLedgerKeys.deleteRange(for: 10...11)
        XCTAssertEqual(r.start, 36_000)
        XCTAssertEqual(r.end, 12 * 3600 - 1)
    }

    func testWorkoutFingerprintTracksWrittenFieldsAndRoute() {
        func fp(kcal: Double? = 300, route: Int = 0, end: Int = 2000) -> UInt64 {
            HealthWriteBackLedgerKeys.workout(startTs: 1000, endTs: end, sport: "Run", energyKcal: kcal,
                                              distanceM: 5000, routeToken: route)
        }
        XCTAssertEqual(fp(), fp())
        XCTAssertNotEqual(fp(), fp(kcal: 301))
        XCTAssertNotEqual(fp(), fp(kcal: nil))
        XCTAssertNotEqual(fp(), fp(route: 1), "a route that appears after the first write must trigger a rewrite")
        XCTAssertNotEqual(fp(), fp(end: 2100))
    }
}
