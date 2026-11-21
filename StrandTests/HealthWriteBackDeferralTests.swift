import XCTest
@testable import Strand

/// A locked HealthKit store defers the write-back to the next unlock instead of invalidating the ledger.
final class HealthWriteBackDeferralTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = "strap-A"

    private func store() -> HealthWriteBackLedgerStore {
        HealthWriteBackLedgerStore(fileURL: nil, build: "2.0.9+1")
    }

    // MARK: classification

    func testClassifyTable() {
        typealias D = HealthWriteBackDeferral
        XCTAssertEqual(D.classify(deleted: 5, isDatabaseInaccessible: false, isNoData: false), .deleted(5))
        XCTAssertEqual(D.classify(deleted: 0, isDatabaseInaccessible: false, isNoData: false), .deleted(0))
        XCTAssertEqual(D.classify(deleted: nil, isDatabaseInaccessible: true, isNoData: false), .inaccessible)
        XCTAssertEqual(D.classify(deleted: nil, isDatabaseInaccessible: false, isNoData: true), .deleted(0))
        XCTAssertEqual(D.classify(deleted: nil, isDatabaseInaccessible: false, isNoData: false), .failed)
    }

    func testActionTable() {
        typealias D = HealthWriteBackDeferral
        XCTAssertEqual(D.action(for: .deleted(3)), .proceed)
        XCTAssertEqual(D.action(for: .inaccessible), .deferUntilUnlock(invalidateSection: false))
        XCTAssertEqual(D.action(for: .inaccessible, deletedSoFar: 120), .deferUntilUnlock(invalidateSection: true))
        XCTAssertEqual(D.action(for: .failed), .failAndCount)
        XCTAssertEqual(D.action(for: .failed, deletedSoFar: 120), .failAndCount)
    }

    func testDeferOnlyWhileProtectedDataIsUnavailable() {
        XCTAssertTrue(HealthWriteBackDeferral.shouldDeferNow(isProtectedDataAvailable: false))
        XCTAssertFalse(HealthWriteBackDeferral.shouldDeferNow(isProtectedDataAvailable: true))
    }

    // MARK: one pass at unlock

    func testManyLockedRequestsOweOnePass() {
        var debt = HealthWriteBackDeferral.UnlockDebt()
        XCTAssertFalse(debt.takeAtUnlock(), "nothing owed before any request")
        for _ in 0..<9 { debt.note() }
        XCTAssertTrue(debt.takeAtUnlock())
        XCTAssertFalse(debt.takeAtUnlock(), "the debt is paid once")
    }

    // MARK: the ledger stays incremental

    func testDeferralWithNothingDeletedLeavesTheLedgerIncremental() {
        let s = store()
        let d: [String: UInt64] = ["a": 1, "b": 2]
        s.commit(s.plan(.heartRate, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        // A locked pass: the delete came back inaccessible with nothing deleted, so the bridge touches nothing.
        if case .deferUntilUnlock(let invalidate) = HealthWriteBackDeferral.action(for: .inaccessible, deletedSoFar: 0) {
            XCTAssertFalse(invalidate)
        } else { XCTFail("must defer") }
        let afterUnlock = s.plan(.heartRate, desired: ["a": 1, "b": 3], scope: scope,
                                 now: t0.addingTimeInterval(3600), enabled: true)
        XCTAssertFalse(afterUnlock.fullRewrite)
        XCTAssertEqual(afterUnlock.dirty, ["b"])
    }

    func testDeferralAfterAPartialDeleteInvalidatesOnlyThatSection() throws {
        let s = store()
        let d: [String: UInt64] = ["a": 1]
        s.commit(s.plan(.heartRate, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        s.commit(s.plan(.sleep, desired: d, scope: scope, now: t0, enabled: true), now: t0, enabled: true)
        s.invalidate(.heartRate) // what the bridge does when invalidateSection is true
        XCTAssertTrue(s.plan(.heartRate, desired: d, scope: scope, now: t0, enabled: true).fullRewrite)
        XCTAssertFalse(s.plan(.sleep, desired: d, scope: scope, now: t0, enabled: true).fullRewrite)
    }

    func testARealRefusalStillCountsAndInvalidates() throws {
        let s = store()
        let d: [String: UInt64] = ["a": 1]
        let plan = s.plan(.sleep, desired: d, scope: scope, now: t0, enabled: true)
        s.commit(plan, now: t0, enabled: true)
        XCTAssertNoThrow(try s.settleOrFail(plan, deleteFailed: true, now: t0))
        XCTAssertNoThrow(try s.settleOrFail(plan, deleteFailed: true, now: t0))
        XCTAssertThrowsError(try s.settleOrFail(plan, deleteFailed: true, now: t0), "third failure in a row surfaces")
        XCTAssertTrue(s.plan(.sleep, desired: d, scope: scope, now: t0, enabled: true).fullRewrite)
    }
}
