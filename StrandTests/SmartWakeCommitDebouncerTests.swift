import XCTest
@testable import Strand

final class SmartWakeCommitDebouncerTests: XCTestCase {
    /// A clock and a timer driven by hand: `advance` moves time forward and runs every timer that falls due, in order.
    private final class Rig {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        private var timers: [(due: Date, work: () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            timers.append((now.addingTimeInterval(delay), work))
        }

        func advance(by seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let index = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due }) {
                let timer = timers.remove(at: index)
                now = timer.due
                timer.work()
            }
            now = target
        }

        func debouncer(quiet: TimeInterval = 1.5, maximumWait: TimeInterval = 8) -> SmartWakeCommitDebouncer {
            SmartWakeCommitDebouncer(quiet: quiet, maximumWait: maximumWait, now: { self.now }, schedule: schedule)
        }
    }

    func testAPickerBurstIsOneCommitAfterTheQuietPeriod() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var commits = 0
        // Five picker steps inside eight seconds (the bug report: five reinstalls in eight seconds).
        for _ in 0..<5 {
            debouncer.request { commits += 1 }
            rig.advance(by: 0.9)
        }
        XCTAssertEqual(commits, 0, "still being edited: nothing committed yet")
        XCTAssertTrue(debouncer.hasPending)
        rig.advance(by: 0.5)
        XCTAssertEqual(commits, 0, "1.4 s since the last step is not quiet yet")
        rig.advance(by: 0.2)
        XCTAssertEqual(commits, 1, "one commit once 1.5 s passed without a new request")
        rig.advance(by: 30)
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(debouncer.hasPending)
    }

    func testTheLatestRequestIsTheOneThatRuns() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var ran: [String] = []
        debouncer.request { ran.append("first") }
        rig.advance(by: 0.5)
        debouncer.request { ran.append("second") }
        rig.advance(by: 2)
        XCTAssertEqual(ran, ["second"])
    }

    func testFlushRunsThePendingCommitOnceAndTheTimerThenDoesNothing() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var commits = 0
        debouncer.request { commits += 1 }
        rig.advance(by: 0.3)
        XCTAssertTrue(debouncer.flush())
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(debouncer.hasPending)
        rig.advance(by: 5)
        XCTAssertEqual(commits, 1, "the timer of the flushed request is stale")
        XCTAssertFalse(debouncer.flush(), "nothing pending")
    }

    func testSupersededTimersDoNotCommit() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var commits = 0
        debouncer.request { commits += 1 }
        rig.advance(by: 1.4)             // the first timer is 0.1 s from firing
        debouncer.request { commits += 1 }
        rig.advance(by: 0.2)             // the first timer fires now and must not commit
        XCTAssertEqual(commits, 0)
        rig.advance(by: 1.4)
        XCTAssertEqual(commits, 1)
    }

    func testABurstThatNeverGoesQuietStillCommitsAfterTheMaximumWait() {
        let rig = Rig()
        let debouncer = rig.debouncer(quiet: 1.5, maximumWait: 8)
        var commits = 0
        var elapsed = 0.0
        while elapsed < 7.5 {
            debouncer.request { commits += 1 }
            rig.advance(by: 1)
            elapsed += 1
        }
        XCTAssertEqual(commits, 0, "a request every second keeps postponing it")
        debouncer.request { commits += 1 }   // eight seconds after the first request of the burst
        XCTAssertEqual(commits, 1, "the maximum wait forces it")
        rig.advance(by: 10)
        XCTAssertEqual(commits, 1)
    }

    func testTwoSeparateBurstsAreTwoCommits() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var commits = 0
        debouncer.request { commits += 1 }
        rig.advance(by: 2)
        debouncer.request { commits += 1 }
        debouncer.request { commits += 1 }
        rig.advance(by: 2)
        XCTAssertEqual(commits, 2)
    }

    func testFlushOnAnEmptyDebouncerDoesNothing() {
        let rig = Rig()
        XCTAssertFalse(rig.debouncer().flush())
    }

    func testACommitThatRequestsAgainStartsANewBurst() {
        let rig = Rig()
        let debouncer = rig.debouncer()
        var commits = 0
        func commit() {
            commits += 1
            if commits == 1 { debouncer.request(commit) }   // e.g. a commit that finds one more change to apply
        }
        debouncer.request(commit)
        rig.advance(by: 1.6)
        XCTAssertEqual(commits, 1)
        XCTAssertTrue(debouncer.hasPending)
        rig.advance(by: 1.6)
        XCTAssertEqual(commits, 2)
    }
}
