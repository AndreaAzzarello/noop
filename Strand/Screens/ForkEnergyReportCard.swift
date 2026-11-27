import SwiftUI
import StrandDesign

// fork-perf: TEMP — Test Centre card for the energy audit. Remove with the TEMP commit.

/// Shows the per-hour counters and the MetricKit daily summary, with a copy/share action.
struct ForkEnergyReportCard: View {
    @State private var text = ""
    @AppStorage(ForkMainStackSampler.disableKey) private var samplerOff = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(verbatim: "ENERGY AUDIT (TEMP)")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "Counts and durations only, no health data. Leave NOOP in normal use for 24 h, then copy this.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: Binding(get: { !samplerOff }, set: { on in
                    samplerOff = !on
                    if on { ForkMainStackSampler.start() } else { ForkMainStackSampler.stop() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Main-thread stack sampler", tableName: "Fork").font(StrandFont.subhead)
                        Text("Samples what the main thread runs during slow run-loop iterations. Function names and counts only.",
                             tableName: "Fork")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .tint(StrandPalette.accent)
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
