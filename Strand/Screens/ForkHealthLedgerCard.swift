import SwiftUI
import StrandDesign

/// Test Centre switch for the Apple Health write-back ledger. On by default; off restores the previous behaviour
/// (delete and rewrite everything on each pass) at the next write-back, with no new build.
struct ForkHealthLedgerCard: View {
    @AppStorage(HealthWriteBackLedgerStore.switchKey) private var ledgerOn = true

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Health write-back ledger", tableName: "Fork")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Toggle(isOn: $ledgerOn) {
                    Text("Write only what changed to Apple Health", tableName: "Fork")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                Text("Each pass rewrites only the vitals, nights, heart-rate hours and workouts that changed, and everything again once a day or after an update. Turn it off to rewrite all of it on every pass.", tableName: "Fork")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
