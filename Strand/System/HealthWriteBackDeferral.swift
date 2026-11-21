import Foundation

/// How the Apple Health write-back reacts to a delete that did not go through.
///
/// WHY. While the phone is locked the HealthKit store is unreadable (`errorDatabaseInaccessible`), so every delete
/// throws. The bridge used to read any throw as "Health refused", invalidate the ledger section and let the next pass
/// rewrite all of it, which failed again, in a chain (measured overnight: 8-10 write-backs per hour, 24-33 full
/// rewrites per hour, 40-55 failed deletes per hour, no observer wake).
///
/// A locked store is not a refusal. It defers the pass to the next unlock and leaves the ledger alone.
///
/// Pure value logic, no HealthKit, so the table of cases runs in `StrandTests`.
enum HealthDeleteOutcome: Equatable {
    /// The delete ran. `n` samples went (zero is a success: nothing was there).
    case deleted(Int)
    /// The store is locked (protected data unavailable). Nothing was touched.
    case inaccessible
    /// The delete threw for any other reason.
    case failed
}

enum HealthWriteBackDeferral {

    /// What the section does with an outcome.
    enum Action: Equatable {
        /// Go on: save, then commit the ledger.
        case proceed
        /// Stop the whole pass until the next unlock. `invalidateSection` is true only when part of the section was
        /// already deleted, so the ledger no longer describes what Health holds. No failure is counted either way.
        case deferUntilUnlock(invalidateSection: Bool)
        /// A real refusal: invalidate the section and count it (the existing rule).
        case failAndCount
    }

    /// Map a HealthKit error onto an outcome. `isNoData` (`errorNoData`) means nothing matched, which is not a failure.
    static func classify(deleted: Int?, isDatabaseInaccessible: Bool, isNoData: Bool) -> HealthDeleteOutcome {
        if let deleted { return .deleted(deleted) }
        if isDatabaseInaccessible { return .inaccessible }
        if isNoData { return .deleted(0) }
        return .failed
    }

    /// `deletedSoFar` counts samples this section already removed before the outcome arrived (the incremental
    /// heart-rate pass deletes one range per run of hours).
    static func action(for outcome: HealthDeleteOutcome, deletedSoFar: Int = 0) -> Action {
        switch outcome {
        case .deleted: return .proceed
        case .inaccessible: return .deferUntilUnlock(invalidateSection: deletedSoFar > 0)
        case .failed: return .failAndCount
        }
    }

    /// True while a pass has to wait: protected data is locked, so no HealthKit or SQLite work is worth starting.
    static func shouldDeferNow(isProtectedDataAvailable: Bool) -> Bool { !isProtectedDataAvailable }

    /// One owed pass at unlock, however many requests arrived while the phone was locked.
    struct UnlockDebt: Equatable {
        private(set) var owed = false
        mutating func note() { owed = true }
        /// Returns true once, when a pass is owed, and clears it.
        mutating func takeAtUnlock() -> Bool {
            defer { owed = false }
            return owed
        }
    }
}

/// Thrown from a write-back section when the store turned out to be locked mid-pass. The pass stops, `lastError` stays
/// untouched and one pass is owed at the next unlock.
struct DeferredUntilUnlock: Error {}
