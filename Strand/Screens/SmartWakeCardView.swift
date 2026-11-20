#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign

/// Phone-based Smart Wake settings card, shown on the Alarms screen. Its maximum time and weekday rules
/// are shared with the WHOOP alarm; only the early-detection window is configured separately.
///
/// A view of its own so the Alarms screen's frequent redraws (it observes `AppModel`, which publishes
/// about once a second while the strap streams heart rate) do not rebuild it: it is `Equatable` on the
/// two inputs it takes from its parent, and otherwise redraws only when `BehaviorStore` or its own state
/// changes. `model` is held without observing it; the card only calls `applySmartWakeSchedule()`.
struct SmartWakeCardView: View, Equatable {
    let model: AppModel
    /// The per-day wake overrides, handed down by `SmartAlarmView` (which already mirrors them) so the card
    /// shows the same times as the "Next buzz" line and does not decode them again on every redraw.
    let overrides: [Int: Int]

    @EnvironmentObject private var behavior: BehaviorStore
    @State private var smartWakeAuthorizationFailed = false
    @State private var smartWakeErrorMessage: String?
    @ObservedObject private var alarms = SmartWakeAlarmStore.shared
    @State private var showList = false

    static func == (lhs: SmartWakeCardView, rhs: SmartWakeCardView) -> Bool {
        lhs.model === rhs.model && lhs.overrides == rhs.overrides
    }

    var body: some View {
        StrandCard(padding: 20, tint: behavior.smartWakeEnabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SMART WAKE", tableName: "Fork").strandOverline()
                    Text("Earlier wake in light sleep", tableName: "Fork")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("NOOP estimates light sleep from WHOOP heart rate and beat intervals and wakes you earlier inside the window, with the strap and the iPhone. It is an estimate, not a measured sleep stage. If samples are missing or insufficient, the maximum-time AlarmKit alarm remains scheduled.", tableName: "Fork")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $behavior.smartWakeEnabled) { Text("Enable Smart Wake", tableName: "Fork") }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)

                if behavior.smartWakeEnabled {
                    LiveActivitiesNotice()
                    Divider().overlay(StrandPalette.hairline)
                    // fork: the alarm list owns the times, days, windows and insistence; this card only summarises it.
                    Text(listSummary)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let next = nextLine {
                        Text(next)
                            .font(StrandFont.number(18))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    Button { showList = true } label: {
                        HStack {
                            Text("Manage alarms", tableName: "Fork")
                            Spacer()
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the list of Smart Wake alarms", tableName: "Fork"))
                }
                if smartWakeAuthorizationFailed {
                    if #available(iOS 26.0, *) {
                        smartWakeErrorText
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("System Smart Wake alarms require iOS 26 or later.", tableName: "Fork")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if #available(iOS 26.0, *) { SmartWakeDiagnosticsView() }
            }
        }
        .sheet(isPresented: $showList) {
            SmartWakeAlarmListView(model: model).environmentObject(behavior)
        }
        .onChangeCompat(of: behavior.smartWakeEnabled) { enabled in
            if enabled {
                alarms.attach(behavior: behavior, model: model)
                alarms.mirrorUpstream()
                if #available(iOS 26.0, *) {
                    // fork: with no active alarm there is nothing to arm yet; the first alarm switched on goes through
                    // the enable path (see `commitSmartWakeSchedule`).
                    guard let schedule = SmartWakeLiveWiring.refreshSchedule(from: behavior) else {
                        smartWakeAuthorizationFailed = false
                        model.applySmartWakeSchedule()
                        return
                    }
                    Task {
                        let outcome = await SmartWakeAlarmScheduler.shared.enable(schedule: schedule)
                        // Not authorized: toggle off. Authorized but AlarmKit refused part of it: stay on, show
                        // why, and let the next foreground sync retry (nothing already armed is removed).
                        smartWakeErrorMessage = outcome == .enabled ? nil : SmartWakeAlarmScheduler.shared.lastErrorDescription
                        smartWakeAuthorizationFailed = outcome != .enabled
                        if outcome == .notAuthorized { behavior.smartWakeEnabled = false }
                        if outcome == .enabled { model.applySmartWakeSchedule() }
                    }
                } else {
                    behavior.smartWakeEnabled = false
                    smartWakeAuthorizationFailed = true
                }
            } else if #available(iOS 26.0, *) {
                smartWakeAuthorizationFailed = !SmartWakeAlarmScheduler.shared.isConfigured
                Task { await SmartWakeAlarmScheduler.shared.disable() }
            } else {
                smartWakeAuthorizationFailed = false
            }
        }
        .onAppear {
            guard behavior.smartWakeEnabled else { return }
            alarms.attach(behavior: behavior, model: model)
            if #available(iOS 26.0, *) {
                if SmartWakeAlarmScheduler.shared.isDenied {
                    smartWakeErrorMessage = SmartWakeAlarmScheduler.shared.lastErrorDescription
                    behavior.smartWakeEnabled = false
                    smartWakeAuthorizationFailed = true
                }
            } else {
                behavior.smartWakeEnabled = false
                smartWakeAuthorizationFailed = true
            }
        }
    }

    /// Shown to the user; the stored error stays English (it is also diagnostics text). The revoked-permission
    /// message is recognised and shown in the app language; any other AlarmKit error gets the generic line, then
    /// the technical detail verbatim so a bug report can still quote it.
    @available(iOS 26.0, *)
    @ViewBuilder
    private var smartWakeErrorText: some View {
        if let detail = smartWakeErrorMessage {
            if detail == SmartWakeAlarmScheduler.revokedAuthorizationMessage {
                Text("Alarm permission was revoked in Settings.", tableName: "Fork")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOOP could not schedule the system alarm. Check the Alarms permission and try again.", tableName: "Fork")
                    Text(verbatim: "\(String(localized: "Technical detail", table: "Fork")): \(detail)")
                }
            }
        } else {
            Text("NOOP could not schedule the system alarm. Check the Alarms permission and try again.", tableName: "Fork")
        }
    }

    private var listSummary: String {
        let active = alarms.book.enabledAlarms.filter { !$0.weekdays.isEmpty }.count
        if active == 0 { return String(localized: "No active alarms. Add or switch one on in the list.", table: "Fork") }
        return String(localized: "\(active) active alarms", table: "Fork")
    }

    private var nextLine: String? {
        guard let next = alarms.next() else { return nil }
        let when = Self.nextFormatter().string(from: next.date)
        return next.label.isEmpty ? when : "\(when) · \(next.label)"
    }

    /// Building a template-based `DateFormatter` is expensive, so one is kept and rebuilt only when the
    /// app language changes (`AppLanguage.activeLocale` is an in-app setting).
    private static var cachedNextFormatter: (localeID: String, formatter: DateFormatter)?

    private static func nextFormatter() -> DateFormatter {
        let locale = AppLanguage.activeLocale
        if let cached = cachedNextFormatter, cached.localeID == locale.identifier {
            return cached.formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        cachedNextFormatter = (locale.identifier, formatter)
        return formatter
    }
}
#endif
