#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign
import UIKit

/// Collapsed "Diagnostics" row inside the Smart Wake card: what the scheduler last did and why, with a
/// button that copies it all. Read-only; it changes nothing about the alarms.
@available(iOS 26.0, *)
struct SmartWakeDiagnosticsView: View {
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(report)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                    Button("Refresh") {
                        reload()
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
            }
            .padding(.top, 6)
        } label: {
            Text("Diagnostics")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .tint(StrandPalette.accent)
        .onAppear { reload() }
    }

    private func reload() {
        copied = false
        report = SmartWakeDiagnostics.report(
            snapshot: SmartWakeAlarmScheduler.shared.diagnosticsSnapshot(),
            windowStats: UserDefaults.standard.string(forKey: SmartWakeLiveController.windowSummaryStorageKey)
        )
    }
}
#endif
