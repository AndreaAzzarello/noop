import Foundation

// fork: merges a burst of "apply the Smart Wake schedule" requests into one commit.
//
// Every request used to run the whole sync at once: the time picker fires one change per step, and each foreground and
// reconnect asks as well, so a few seconds of scrolling gave five "reinstalling fallbacks" in eight seconds. Here a
// request only marks work as pending; the commit runs once, after `quiet` seconds without a new request. Until then the
// alarms already installed stay armed (nothing is removed or replaced early), so a pending commit never leaves a day
// uncovered.
//
// Pure Foundation. The clock and the timer are injected so tests drive both by hand. Main thread only.

final class SmartWakeCommitDebouncer {
    static let shared = SmartWakeCommitDebouncer()
    static let defaultQuiet: TimeInterval = 1.5
    /// A burst that never goes quiet (a request every second for a minute) still commits this long after its first one.
    static let defaultMaximumWait: TimeInterval = 8

    /// Runs `work` after `delay` seconds. Injected so tests drive the timer by hand.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let quiet: TimeInterval
    private let maximumWait: TimeInterval
    private let now: () -> Date
    private let schedule: Scheduler
    private var pending: (() -> Void)?
    private var firstPendingAt: Date?
    private var generation = 0

    init(quiet: TimeInterval = SmartWakeCommitDebouncer.defaultQuiet,
         maximumWait: TimeInterval = SmartWakeCommitDebouncer.defaultMaximumWait,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.quiet = quiet
        self.maximumWait = maximumWait
        self.now = now
        self.schedule = schedule
    }

    /// True while a request is waiting for its commit.
    var hasPending: Bool { pending != nil }

    /// Asks for a commit. The latest `commit` given is the one that runs, once, after `quiet` seconds with no new request
    /// (or at once when the burst has already lasted `maximumWait`).
    func request(_ commit: @escaping () -> Void) {
        pending = commit
        let t = now()
        let first = firstPendingAt ?? t
        firstPendingAt = first
        if t.timeIntervalSince(first) >= maximumWait {
            fire()
            return
        }
        generation += 1
        let mine = generation
        schedule(quiet) { [weak self] in self?.timerFired(generation: mine) }
    }

    /// Runs the pending commit now, if there is one. For the app going to the background and for a screen that closes,
    /// where waiting for the quiet period could mean never. Returns whether it ran one.
    @discardableResult
    func flush() -> Bool {
        guard pending != nil else { return false }
        fire()
        return true
    }

    private func timerFired(generation fired: Int) {
        guard fired == generation, pending != nil else { return }   // a later request owns the timer now
        fire()
    }

    private func fire() {
        let commit = pending
        pending = nil
        firstPendingAt = nil
        generation += 1   // timers scheduled before this point find a different generation and do nothing
        commit?()
    }
}
