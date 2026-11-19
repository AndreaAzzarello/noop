import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// fork-perf: overlapping `Repository.refresh()` calls share passes. These pin the three guarantees the
/// coalescer documents: no call is lost, the last state wins, and nothing deadlocks.
@MainActor
final class RefreshCoalescerTests: XCTestCase {

    /// A pass whose completion the test controls, and which records when it started and with which window.
    @MainActor
    private final class Harness {
        var started: [Int] = []                 // `days` of each pass, in start order
        var events: [String] = []               // "start:N" / "end:N" / "return:X", in order
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var gated = true

        func pass(_ days: Int) async {
            started.append(days)
            let index = started.count
            events.append("start:\(index)")
            if gated {
                await withCheckedContinuation { gates.append($0) }
            } else {
                // A real pass suspends on its store reads; without this the fake never overlaps another call.
                for _ in 0..<5 { await Task.yield() }
            }
            events.append("end:\(index)")
        }

        /// Lets the pass in flight finish (and every later pass run straight through when `all`).
        func release(all: Bool = false) {
            if all { gated = false }
            let g = gates
            gates = []
            g.forEach { $0.resume() }
        }

        var waitingPasses: Int { gates.count }
    }

    /// Yields until `condition` holds, or fails after a bounded number of turns (no wall-clock sleep).
    private func spin(_ message: String, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for: \(message)", file: file, line: line)
    }

    /// Runs `body` and reports whether it finished within `seconds`. Unstructured on purpose: a deadlocked
    /// body must fail the test, not hang the suite waiting for a child task that can never end.
    private func withTimeout(_ seconds: Double, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        var done = false
        let task = Task { @MainActor in await body(); done = true }
        for _ in 0..<Int(seconds * 100) {
            if done { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = task
        return done
    }

    // MARK: - No refresh lost

    /// Three callers overlap: the first runs a pass, the other two share ONE follow-up that starts after both
    /// arrived, and nobody returns before that follow-up has finished.
    func testCallsDuringAPassShareOneFollowUpThatStartsAfterTheyArrived() async {
        let c = RefreshCoalescer(), h = Harness()
        let a = Task { @MainActor in await c.run(days: 4000, pass: h.pass); h.events.append("return:a") }
        await spin("first pass started") { h.started.count == 1 }
        let b = Task { @MainActor in await c.run(days: 120, pass: h.pass); h.events.append("return:b") }
        let d = Task { @MainActor in await c.run(days: 4000, pass: h.pass); h.events.append("return:d") }
        await spin("both joiners counted") { c.coalescedCount == 2 }
        XCTAssertEqual(h.started.count, 1, "joiners must not start their own pass")

        h.release()                                   // first pass ends -> exactly one follow-up starts
        await spin("follow-up started") { h.started.count == 2 }
        XCTAssertFalse(h.events.contains("return:a"), "the owner must wait for the follow-up the joiners need")
        XCTAssertEqual(Array(h.events.prefix(3)), ["start:1", "end:1", "start:2"],
                       "the follow-up starts only after the first pass ended, hence after both joiners arrived")

        h.release()
        _ = await (a.value, b.value, d.value)
        XCTAssertEqual(h.started.count, 2, "three calls, two passes")
        XCTAssertEqual(h.events.filter { $0.hasPrefix("return") }.count, 3, "every caller returned")
        XCTAssertEqual(Set(h.events.filter { $0.hasPrefix("return") }), ["return:a", "return:b", "return:d"])
        for r in ["return:a", "return:b", "return:d"] {
            XCTAssertGreaterThan(h.events.firstIndex(of: r)!, h.events.firstIndex(of: "end:2")!,
                                 "\(r) returned before the follow-up finished")
        }
    }

    /// The follow-up asks for the widest window any joiner asked for.
    func testFollowUpUsesTheWidestRequestedWindow() async {
        let c = RefreshCoalescer(), h = Harness()
        let a = Task { @MainActor in await c.run(days: 120, pass: h.pass) }
        await spin("first pass started") { h.started.count == 1 }
        let b = Task { @MainActor in await c.run(days: 30, pass: h.pass) }
        let d = Task { @MainActor in await c.run(days: 4000, pass: h.pass) }
        await spin("joiners counted") { c.coalescedCount == 2 }
        h.release(all: true)
        _ = await (a.value, b.value, d.value)
        XCTAssertEqual(h.started, [120, 4000])
    }

    /// A call that arrives DURING the follow-up is not folded into it: it gets a pass of its own after it.
    func testCallArrivingDuringTheFollowUpGetsAnotherPass() async {
        let c = RefreshCoalescer(), h = Harness()
        let a = Task { @MainActor in await c.run(days: 10, pass: h.pass) }
        await spin("pass 1") { h.started.count == 1 }
        let b = Task { @MainActor in await c.run(days: 20, pass: h.pass) }
        await spin("b joined") { c.coalescedCount == 1 }
        h.release()
        await spin("pass 2 (follow-up) started") { h.started.count == 2 }
        let late = Task { @MainActor in await c.run(days: 30, pass: h.pass) }
        await spin("late joined") { c.coalescedCount == 2 }
        h.release()
        await spin("pass 3 started") { h.started.count == 3 }
        h.release(all: true)
        _ = await (a.value, b.value, late.value)
        XCTAssertEqual(h.started, [10, 20, 30], "the late call's window was read by a pass that started after it")
    }

    /// Calls that do not overlap each run their own pass, as before.
    func testSequentialCallsEachRunOwnPass() async {
        let c = RefreshCoalescer(), h = Harness()
        h.release(all: true)
        await c.run(days: 1, pass: h.pass)
        await c.run(days: 2, pass: h.pass)
        await c.run(days: 3, pass: h.pass)
        XCTAssertEqual(h.started, [1, 2, 3])
        XCTAssertEqual(c.coalescedCount, 0)
    }

    // MARK: - No deadlock

    func testBurstOfOverlappingCallsAllReturn() async {
        let c = RefreshCoalescer(), h = Harness()
        h.release(all: true)
        let finished = await withTimeout(10) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<50 { group.addTask { @MainActor in await c.run(days: 100 + i, pass: h.pass) } }
            }
        }
        XCTAssertTrue(finished, "a burst of overlapping refreshes must all return (deadlock)")
        XCTAssertLessThan(h.started.count, 50, "a burst must collapse into fewer passes than calls")
    }

    func testCoalescerIsReusableAfterABurst() async {
        let c = RefreshCoalescer(), h = Harness()
        h.release(all: true)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 { group.addTask { @MainActor in await c.run(days: i + 1, pass: h.pass) } }
        }
        let before = h.started.count
        await c.run(days: 7, pass: h.pass)
        XCTAssertEqual(h.started.count, before + 1)
        XCTAssertEqual(h.started.last, 7)
    }

    // MARK: - Last state wins (through the real Repository)

    private func dailyMetric(day: String, recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 230,
                    disturbances: 2, restingHr: 52, avgHrv: 70, recovery: recovery, strain: 8, exerciseCount: 0,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14, steps: nil, activeKcalEst: nil)
    }

    /// Data written while a refresh is in flight is visible once a refresh CALLED AFTER the write returns,
    /// and `refreshSeq` only ever moves forward (an older pass never publishes after a newer one).
    func testRepositoryRefreshCalledAfterAWriteSeesIt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let d1 = Repository.localDayKey(Date().addingTimeInterval(-86_400))
        let d2 = Repository.localDayKey(Date())
        _ = try await store.upsertDailyMetrics([dailyMetric(day: d1, recovery: 60)], deviceId: "my-whoop-noop")

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)

        var seqs: [Int] = [repo.refreshSeq]
        let first = Task { @MainActor in await repo.refresh() }
        await Task.yield()
        _ = try await store.upsertDailyMetrics([dailyMetric(day: d2, recovery: 70)], deviceId: "my-whoop-noop")
        let second = Task { @MainActor in await repo.refresh() }   // called AFTER the write
        let third = Task { @MainActor in await repo.refresh() }
        let finished = await withTimeout(30) { await first.value; await second.value; await third.value }
        XCTAssertTrue(finished, "overlapping refreshes must all return")
        seqs.append(repo.refreshSeq)

        XCTAssertNotNil(repo.days.first(where: { $0.day == d1 }))
        XCTAssertNotNil(repo.days.first(where: { $0.day == d2 }),
                        "a refresh called after the write must publish it (no refresh lost)")
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(seqs, seqs.sorted(), "refreshSeq never goes backwards")
    }
}
