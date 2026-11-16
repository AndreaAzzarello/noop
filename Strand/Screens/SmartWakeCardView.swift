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
    /// Off by default. Read by `SmartWakeStrapAlarm` when a wake-up starts; it changes nothing about the
    /// WHOOP firmware alarm.
    @AppStorage(SmartWakeStrapAlarm.insistentKey) private var insistentStrapAlarm = false

    static func == (lhs: SmartWakeCardView, rhs: SmartWakeCardView) -> Bool {
        lhs.model === rhs.model && lhs.overrides == rhs.overrides
    }

    var body: some View {
        StrandCard(padding: 20, tint: behavior.smartWakeEnabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SMART WAKE").strandOverline()
                    Text("Earlier wake in light sleep")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("NOOP estimates light sleep from WHOOP heart rate and beat intervals and wakes you earlier inside the window, with the strap and the iPhone. It is an estimate, not a measured sleep stage. If samples are missing or insufficient, the maximum-time AlarmKit alarm remains scheduled.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Enable Smart Wake", isOn: $behavior.smartWakeEnabled)
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)

                if behavior.smartWakeEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Maximum wake")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(maximumLabel)
                            .font(StrandFont.number(18))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    HStack {
                        Text("Early window")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Picker("Early window", selection: $behavior.smartWakeWindowMinutes) {
                            ForEach([15, 20, 30, 45, 60], id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Smart Wake early window")
                    }
                    Text("Uses the same active weekdays and per-day wake times as the WHOOP alarm: \(SmartAlarmView.alarmWeekdaySummary(behavior.smartAlarmWeekdays)).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !overrides.isEmpty {
                        Text("Custom times for individual days are included automatically.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    Toggle("Insistent strap alarm", isOn: $insistentStrapAlarm)
                        .toggleStyle(.switch)
                        .tint(StrandPalette.accent)
                    Text("If you don't double-tap the strap, it vibrates again every 5 minutes, up to 6 times. A double tap stops it and the iPhone alarm.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if smartWakeAuthorizationFailed {
                    if #available(iOS 26.0, *) {
                        Text(smartWakeErrorMessage ?? "NOOP could not schedule the system alarm. Check the Alarms permission and try again.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("System Smart Wake alarms require iOS 26 or later.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if #available(iOS 26.0, *) { SmartWakeDiagnosticsView() }
            }
        }
        .onChangeCompat(of: behavior.smartWakeEnabled) { enabled in
            if enabled {
                if #available(iOS 26.0, *) {
                    Task {
                        let outcome = await SmartWakeAlarmScheduler.shared.enable(
                            schedule: SmartWakeLiveWiring.makeSchedule(from: behavior)
                        )
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
        .onChangeCompat(of: behavior.smartWakeWindowMinutes) { _ in
            model.applySmartWakeSchedule()
        }
        .onAppear {
            guard behavior.smartWakeEnabled else { return }
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

    private var maximumLabel: String {
        guard let next = AppModel.nextSmartAlarmDate(
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            overrides: overrides
        ) else { return String(localized: "No active wake days") }
        return Self.maximumFormatter().string(from: next)
    }

    /// Building a template-based `DateFormatter` is expensive, so one is kept and rebuilt only when the
    /// app language changes (`AppLanguage.activeLocale` is an in-app setting).
    private static var cachedMaximumFormatter: (localeID: String, formatter: DateFormatter)?

    private static func maximumFormatter() -> DateFormatter {
        let locale = AppLanguage.activeLocale
        if let cached = cachedMaximumFormatter, cached.localeID == locale.identifier {
            return cached.formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        cachedMaximumFormatter = (locale.identifier, formatter)
        return formatter
    }
}
#endif
