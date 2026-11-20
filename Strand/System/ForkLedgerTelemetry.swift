import Foundation

// fork-perf: TEMP — ledger counters for the energy audit. Remove with the TEMP commit.

enum ForkLedgerTelemetry {
    static func note(_ plan: HealthWriteBackLedger.Plan) {
        let c = ForkEnergyCounters.shared
        c.note(.ledgerSkippedKeys, by: plan.unchangedCount)
        c.note(.ledgerRewrittenKeys, by: plan.dirty.count)
        if plan.fullRewrite { c.note(.ledgerFullRewrite) }
    }
}
