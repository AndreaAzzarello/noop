#if os(iOS)
import Foundation
import HealthKit

/// HealthKit-facing helpers for the write-back ledger, kept out of `HealthKitBridge` so the bridge only carries hooks.
enum HealthWriteBackLedgerHK {

    /// Delete our samples matching `predicate`.
    ///
    /// The bridge used `try?` here, so a failed delete was indistinguishable from "nothing to delete" and the save
    /// that followed could leave the old and the new samples side by side. A failure is now visible to the caller,
    /// and a LOCKED store (`errorDatabaseInaccessible`) is told apart from a refusal: it defers the pass instead of
    /// invalidating the ledger.
    static func delete(_ store: HKHealthStore, of type: HKObjectType, predicate: NSPredicate) async -> HealthDeleteOutcome {
        do {
            let n = try await store.deleteObjects(of: type, predicate: predicate)
            return HealthWriteBackDeferral.classify(deleted: n, isDatabaseInaccessible: false, isNoData: false)
        } catch {
            let code = (error as? HKError)?.code
            return HealthWriteBackDeferral.classify(deleted: nil,
                                                    isDatabaseInaccessible: code == .errorDatabaseInaccessible,
                                                    isNoData: code == .errorNoData)
        }
    }

    /// Start of the heart-rate window, moved back to a clock-hour boundary when the ledger is on: an hour is the unit
    /// the ledger deletes and rewrites, so the first hour must be read whole. Unchanged when the ledger is off.
    static func alignedHeartRateStart(_ start: Int, enabled: Bool) -> Int {
        guard enabled else { return start }
        return start - start % HealthWriteBackLedgerKeys.hourSeconds
    }

    /// The hours to delete and rewrite for heart rate: every dirty hour, plus the hours the ledger holds inside the
    /// window that no longer have any bucket (deleted, nothing to save). Hours older than the window are ignored.
    static func heartRateHours(plan: HealthWriteBackLedger.Plan, windowStart: Int) -> (dirty: Set<Int>, deleteOnly: Set<Int>) {
        let dirty = Set(plan.dirty.compactMap(Int.init))
        let firstHour = windowStart / HealthWriteBackLedgerKeys.hourSeconds
        let deleteOnly = Set(plan.removed.compactMap(Int.init).filter { $0 >= firstHour })
        return (dirty, deleteOnly)
    }

    /// Delete the heart-rate samples this pass is about to rewrite.
    ///
    /// A full rewrite deletes the whole window in one call, exactly as before. An incremental pass deletes one range
    /// per run of consecutive dirty (or emptied) hours, so only the hours an offload touched are churned.
    static func deleteHeartRate(_ store: HKHealthStore, type: HKObjectType, plan: HealthWriteBackLedger.Plan,
                                hours: (dirty: Set<Int>, deleteOnly: Set<Int>),
                                wholeWindow: NSPredicate) async -> (deleted: Int, outcome: HealthDeleteOutcome) {
        if plan.fullRewrite {
            let outcome = await delete(store, of: type, predicate: wholeWindow)
            if case .deleted(let n) = outcome { return (n, outcome) }
            return (0, outcome)
        }
        var total = 0
        var worst: HealthDeleteOutcome = .deleted(0)
        for run in HealthWriteBackLedgerKeys.runs(of: Array(hours.dirty.union(hours.deleteOnly))) {
            let range = HealthWriteBackLedgerKeys.deleteRange(for: run)
            let outcome = await delete(store, of: type, predicate: ownHeartRatePredicate(start: range.start, end: range.end))
            switch outcome {
            case .deleted(let n): total += n
            case .inaccessible: return (total, .inaccessible) // the store locked mid-pass: stop here
            case .failed: worst = .failed
            }
        }
        if case .failed = worst { return (total, .failed) }
        return (total, .deleted(total))
    }

    /// The predicate that matches our own heart-rate samples starting inside `[start, end]`.
    ///
    /// `.strictStartDate` and an end one second short of the next hour: a 1-minute sample belongs to the hour it
    /// STARTS in, and a neighbouring hour that the ledger considers unchanged must never lose a sample to a boundary
    /// the store reads the other way.
    static func ownHeartRatePredicate(start: Int, end: Int) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(start)),
                                        end: Date(timeIntervalSince1970: TimeInterval(end)),
                                        options: [.strictStartDate]),
        ])
    }
}
#endif
