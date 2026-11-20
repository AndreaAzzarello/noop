import Foundation

/// fork-perf: serialises overlapping `Repository.refresh()` calls.
///
/// A launch fires several refreshes at once (app model, tab shell, Health sync, re-score). Each one read the
/// whole store and merged it, and all but the last were dropped by the generation guard, so the work was
/// done N times for one published result. Now at most one pass runs at a time. A call that arrives while a
/// pass is running does not start its own: it records the widest window it asked for and waits for ONE
/// follow-up pass that starts after it arrived, so the data it sees is never older than its own call.
///
/// Guarantees (covered by `RefreshCoalescerTests`):
/// - no call is lost: every caller returns only after a pass that STARTED after the call was made;
/// - the last state wins: passes never overlap, so an older pass can not publish after a newer one;
/// - no deadlock: the loop ends as soon as no call arrived during the last pass, then resumes every waiter.
@MainActor
final class RefreshCoalescer {
    private var running = false
    private var pendingDays: Int?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Calls that waited for a follow-up pass instead of starting their own.
    private(set) var coalescedCount = 0

    /// Runs `pass(days)` now, or joins the pass in flight. `pass` must not call back into this coalescer
    /// and wait for it (that would wait on itself).
    func run(days: Int, pass: (Int) async -> Void) async {
        if running {
            pendingDays = max(pendingDays ?? 0, days)
            coalescedCount += 1
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        var next = days
        while true {
            await pass(next)
            guard let again = pendingDays else { break }
            pendingDays = nil
            next = again
        }
        running = false
        let release = waiters
        waiters = []
        for w in release { w.resume() }
    }
}
