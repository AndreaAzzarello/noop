#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign
import UIKit

/// Collapsed "Diagnostics" row inside the Smart Wake card: what the scheduler last did and why, with a
/// button that copies it all, a one-minute test of the strap's firmware alarm, and a one-minute test of the
/// iPhone alarm (`SmartWakeTestAlarm`, isolated from the schedule). The report is read-only; only the strap test
/// arms the strap, and it restores the normal alarm when it ends.
@available(iOS 26.0, *)
struct SmartWakeDiagnosticsView: View {
    @State private var report = ""
    @State private var copied = false
    @State private var testResult: String?
    @State private var phoneTestResult: String?

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
                Button {
                    Task {
                        phoneTestResult = await SmartWakeTestAlarm.shared.arm()
                        reload()
                    }
                } label: {
                    Text("Test iPhone alarm in 1 minute", tableName: "Fork")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                if let phoneTestResult {
                    Text(verbatim: phoneTestResult)
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
        Task { await SmartWakeTestAlarm.shared.sweep() }
        // TEMP probe: the NOOP+ extra-large widget's real size and block data (see NOOPPlusProvider).
        let probe = UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: "noop.fork.widget.xlProbe")
        // TEMP: what the APP sees in the same snapshot, and which pass wrote last (see ForkWidgetPublisher).
        let fork = ForkWidgetSnapshot.load()
        let trace = (UserDefaults.standard.dictionary(forKey: ForkWidgetPublisher.writeTraceKey) as? [String: String] ?? [:])
            .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " | ")
        let forkLine = "NOOP+ snapshot (app): fork="
            + (fork.map { $0.publishedAt.formatted(date: .omitted, time: .shortened) } ?? "none")
            + " fmt=\(fork?.formatVersion.map(String.init) ?? "nil") | \(trace.isEmpty ? "no pass yet" : trace)"
        report = SmartWakeDiagnostics.report(
            snapshot: SmartWakeAlarmScheduler.shared.diagnosticsSnapshot()
                + "\n" + SmartWakeTestAlarm.shared.statusLine
                + "\nNOOP+ XL probe: \(probe ?? "no extra-large widget has rendered yet")"
                + "\n" + forkLine,
            windowStats: UserDefaults.standard.string(forKey: SmartWakeLiveController.windowSummaryStorageKey)
        )
    }
}
#endif
