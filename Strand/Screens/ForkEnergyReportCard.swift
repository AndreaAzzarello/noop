import SwiftUI
import StrandDesign

// fork-perf: TEMP — Test Centre card for the energy audit. Remove with the TEMP commit.

/// Shows the per-hour counters and the MetricKit daily summary, with a copy/share action.
struct ForkEnergyReportCard: View {
    @State private var text = ""

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(verbatim: "ENERGY AUDIT (TEMP)")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "Counts and durations only, no health data. Leave NOOP in normal use for 24 h, then copy this.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { reload() }, label: { Text(verbatim: "Refresh") })
                    .font(StrandFont.subhead).tint(StrandPalette.accent)
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: text) { Text(verbatim: "Share report").font(StrandFont.subhead) }
                        .tint(StrandPalette.accent)
                }
            }
        }
        .task { reload() }
    }

    private func reload() {
        ForkEnergyCounters.shared.flush()
        text = ForkEnergyCounters.shared.report() + "\n\n" + ForkMetricKitDays.report(ForkMetricKitDays.load())
    }
}
