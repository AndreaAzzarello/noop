import XCTest
@testable import Strand

/// The decision behind "does this Health pass owe one more write-back?". A read-side sync that finds the
/// bridge busy must never owe one (the observer self-trigger loop); fresh strap data owes one only when it
/// landed after the pass had read its rows.
final class HealthWriteBackGateTests: XCTestCase {

    func testNothingRequestedOwesNothing() {
        var gate = HealthWriteBackGate()
        gate.readsStarted()
        XCTAssertEqual(gate.finishPass(), .none)
    }

    /// An observer wake (a busy `sync`) records nothing at all, so it cannot make a second write-back.
    func testBusySyncIsNotRecorded() {
        var gate = HealthWriteBackGate()
        gate.readsStarted()
        // `sync()` busy path: deliberately no call into the gate.
        XCTAssertEqual(gate.finishPass(), .none)
    }

    func testDataBeforeReadsIsCoveredByThePass() {
        var gate = HealthWriteBackGate()
        gate.noteNewData()
        gate.readsStarted()
        XCTAssertEqual(gate.finishPass(), .covered)
    }

    func testDataAfterReadsOwesARerun() {
        var gate = HealthWriteBackGate()
        gate.readsStarted()
        gate.noteNewData()
        XCTAssertEqual(gate.finishPass(), .rerun)
    }

    /// A pass that failed before its write-back wrote nothing, so early data is not covered after all.
    func testDataBeforeReadsOwesARerunWhenThePassNeverReachedItsWriteBack() {
        var gate = HealthWriteBackGate()
        gate.noteNewData()
        XCTAssertEqual(gate.finishPass(), .rerun)
    }

    func testEarlyAndLateTogetherOweOneRerun() {
        var gate = HealthWriteBackGate()
        gate.noteNewData()
        gate.readsStarted()
        gate.noteNewData()
        XCTAssertEqual(gate.finishPass(), .rerun)
    }

    /// Several late announcements still owe exactly one rerun, and the next pass starts clean.
    func testGateResetsAfterEachPass() {
        var gate = HealthWriteBackGate()
        gate.readsStarted()
        gate.noteNewData(); gate.noteNewData(); gate.noteNewData()
        XCTAssertEqual(gate.finishPass(), .rerun)
        XCTAssertFalse(gate.readsBegan)
        XCTAssertEqual(gate.finishPass(), .none)
        gate.readsStarted()
        XCTAssertEqual(gate.finishPass(), .none)
    }
}
