#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign
import UIKit

/// Collapsed "Diagnostics" row inside the Smart Wake card: what the scheduler last did and why, with a
/// button that copies it all, and a one-minute test of the strap's firmware alarm. The report is read-only; only the
/// test arms the strap, and it restores the normal alarm when it ends.
@available(iOS 26.0, *)
struct SmartWakeDiagnosticsView: View {
    @State private var report = ""
    @State private var copied = false
    @State private var testResult: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(report)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    testResult = SmartWakeStrapAlarm.current?.startTest() ?? String(localized: "Not started: Smart Wake is not running", table: "Fork")
                    reload()
                } label: {
                    Text("Test strap alarm in 1 minute", tableName: "Fork")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                if let testResult {
                    Text(verbatim: testResult)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Button(copied ? String(localized: "Copied", table: "Fork") : String(localized: "Copy")) {
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
