#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign
import UIKit

// fork: the Alarms screen while Smart Wake is on. Two panels, "Alarms" (the list and the two switches that decide how
// it wakes you) and "Evening" (the bedtime reminder), plus one Information sheet holding every explanation. With Smart
// Wake off, `SmartAlarmView` shows the classic cards instead and this file is never reached.
//
// The one place a fact is stated is the one place it can be edited: the list owns times, days, windows and insistence
// (`SmartWakeAlarmStore`); the strap switch is `behavior.smartAlarmEnabled`; "Next" comes from `SmartWakeAlarmStore.next`.

/// Fork-table copy as `String`/`Text`, in the app language like the rest of the fork's strings. The key is the literal,
/// so interpolations land in the catalog as `%lld` / `%@`.
enum ForkCopy {
    static func string(_ value: String.LocalizationValue) -> String { String(localized: value, table: "Fork") }
    static func text(_ value: String.LocalizationValue) -> Text { Text(verbatim: string(value)) }
}

struct SmartWakeAlarmsScreen: View {
    let model: AppModel
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var store = SmartWakeAlarmStore.shared

    @State private var editing: SmartWakeAlarm?
    @State private var isNew = false
    @State private var pending: PendingConflict?
    @State private var showInfo = false
    @State private var swipeOpenID: UUID?
    @State private var lastSwipeActivity: Date?
    @State private var deleteTick = 0
    @State private var smartWakeFailure: String?
    @State private var windDownOn = WindDownNudge.isEnabled
    @State private var usualWake = WindDownNudge.wakeMinutes
    @State private var showNotifDeniedAlert = false
    @AppStorage("alarm.rejectStreak") private var alarmRejectStreak = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            alarmsPanel
            eveningPanel
        }
        .liquidMediumHaptic(trigger: deleteTick)
        .sheet(item: $editing) { alarm in
            SmartWakeAlarmEditor(original: alarm, isNew: isNew, onSave: { attemptSave($0) }, onDelete: { store.delete(id: $0) })
        }
        .sheet(isPresented: $showInfo) { SmartWakeAlarmsInfoSheet() }
        .alert(Self.conflictTitle, isPresented: conflictBinding, presenting: pending) { item in
            Button(Self.switchOffTitle(SmartWakeAlarmListView.names(item.conflicts, in: store.book))) {
                store.saveSwitchingOffConflicts(item.alarm)
                editing = nil
            }
            Button(Self.cancelTitle, role: .cancel) {}
        } message: { item in
            Text(SmartWakeAlarmListView.conflictMessage(item.conflicts, in: store.book))
        }
        .alert(Self.notificationsOffTitle, isPresented: $showNotifDeniedAlert) {
            Button(Self.openSettingsTitle) { Self.openSettings() }
            Button(Self.notNowTitle, role: .cancel) {}
        } message: {
            Text("Turn on notifications for NOOP in Settings to get your wind-down reminder.")
        }
        .onAppear {
            store.attach(behavior: behavior, model: model)
            healScheduling()
        }
        .onDisappear { SmartWakeCommitDebouncer.shared.flush() }
    }

    // MARK: Alarms panel

    private var alarmsPanel: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Alarms").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel(Text(verbatim: Self.informationTitle))
                    Button {
                        swipeOpenID = nil
                        isNew = true
                        editing = SmartWakeAlarm(windowMinutes: behavior.smartWakeWindowMinutes)
                    } label: { Image(systemName: "plus") }
                        .disabled(!store.book.canAdd)
                        .accessibilityLabel(Text(verbatim: Self.addTitle))
                }
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)

                nextLine

                if store.book.alarms.isEmpty {
                    ForkCopy.text("No alarms yet. Tap + to add one.")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.book.alarms.enumerated()), id: \.element.id) { index, alarm in
                            if index > 0 { Divider().overlay(StrandPalette.hairline) }
                            SmartWakeAlarmRow(alarm: alarm,
                                              onEdit: { tapRow(alarm) },
                                              onToggle: { setEnabled(alarm, $0) },
                                              onDelete: { delete(alarm) },
                                              onAccessibilityEdit: { openEditor(alarm) })
                                .modifier(SmartWakeSwipeToDelete(rowID: alarm.id, openID: $swipeOpenID,
                                                                 lastDragActivity: $lastSwipeActivity,
                                                                 onDelete: { delete(alarm) }))
                        }
                    }
                }
                if !store.book.canAdd {
                    ForkCopy.text("Maximum \(SmartWakeAlarmBook.maxAlarms) alarms")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }

                Divider().overlay(StrandPalette.hairline)
                Toggle(isOn: $behavior.smartAlarmEnabled) { ForkCopy.text("Vibrate the strap too") }
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
                Toggle(isOn: smartWakeBinding) { ForkCopy.text("Smart Wake") }
                    .tint(StrandPalette.accent)

                notices

                if #available(iOS 26.0, *) {
                    SmartWakeDiagnosticsView()
                    if !model.whoop5Detected {
                        Button { model.ble.getStrapAlarm() } label: {
                            Text("Check what the strap has stored")
                                .font(StrandFont.footnote)
                        }
                        .foregroundStyle(StrandPalette.accent)
                    }
                }
            }
        }
    }

    /// "Next: Mon 07:20", from the one resolver the strap arm, AlarmKit and the Night card share; redrawn each minute.
    @ViewBuilder private var nextLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            if let next = store.next(after: tick.date) {
                let when = Self.nextFormatter().string(from: next.date)
                let text = next.label.isEmpty ? when : "\(when) · \(next.label)"
                Text(verbatim: Self.nextTitle(text))
                    .font(StrandFont.number(18))
                    .foregroundStyle(StrandPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line each, and only while something needs the wearer to act.
    @ViewBuilder private var notices: some View {
        LiveActivitiesNotice()
        if #available(iOS 26.0, *), SmartWakeAlarmScheduler.shared.isDenied || smartWakeFailure != nil {
            notice(ForkCopy.string("Alarm permission is off for NOOP, so the iPhone alarm cannot ring"), action: true)
        }
        if behavior.smartAlarmEnabled, model.whoop5Detected, !PuffinExperiment.isEnabled {
            notice(ForkCopy.string("The strap is not armed: a 5/MG needs Protocol probes"), action: false)
        }
        if behavior.smartAlarmEnabled, alarmRejectStreak >= 2 {
            notice(ForkCopy.string("The strap is not accepting the alarm"), action: false)
        }
    }

    private func notice(_ text: String, action: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning).accessibilityHidden(true)
            Text(verbatim: text)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if action {
                Spacer(minLength: 4)
                Button { Self.openSettings() } label: { ForkCopy.text("Open Settings").font(StrandFont.footnote) }
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Evening panel

    private var eveningPanel: some View {
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(StrandPalette.restColor).accessibilityHidden(true)
                    Text("Evening").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                Toggle(isOn: $windDownOn) { Text("Remind me to wind down") }
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: windDownOn) { on in
                        WindDownNudge.setEnabled(on) { outcome in
                            if outcome == .denied {   // the reminder can never fire: show the truth and the way to Settings
                                windDownOn = false
                                showNotifDeniedAlert = true
                            }
                        }
                    }
                if windDownOn {
                    HStack {
                        Text("Your usual wake time").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: usualWakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Your usual wake time")
                    }
                    Text("You'll be reminded around \(Self.timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    // MARK: Actions

    /// The Smart Wake switch. Turning it ON from the classic card swaps this screen in, so the card's own handler may
    /// not run: `healScheduling` finishes the job on appear. Turning it OFF here removes the system alarms.
    private var smartWakeBinding: Binding<Bool> {
        Binding(get: { behavior.smartWakeEnabled }, set: { setSmartWake($0) })
    }

    private func setSmartWake(_ on: Bool) {
        behavior.smartWakeEnabled = on
        guard !on else { return }
        smartWakeFailure = nil
        if #available(iOS 26.0, *) { Task { await SmartWakeAlarmScheduler.shared.disable() } }
    }

    /// Smart Wake is on but nothing is scheduled with the system: run the same enable path the classic card runs.
    /// Serialized inside the scheduler, so running it next to the card's own handler cannot double-schedule.
    private func healScheduling() {
        guard behavior.smartWakeEnabled else { return }
        guard #available(iOS 26.0, *) else {
            behavior.smartWakeEnabled = false
            return
        }
        if SmartWakeAlarmScheduler.shared.isDenied {
            smartWakeFailure = SmartWakeAlarmScheduler.shared.lastErrorDescription ?? ""
            behavior.smartWakeEnabled = false
            return
        }
        guard !SmartWakeAlarmScheduler.shared.isConfigured else { return }
        store.mirrorUpstream()
        guard let schedule = SmartWakeLiveWiring.refreshSchedule(from: behavior) else {
            model.applySmartWakeSchedule()
            return
        }
        Task {
            let outcome = await SmartWakeAlarmScheduler.shared.enable(schedule: schedule)
            smartWakeFailure = outcome == .enabled ? nil : (SmartWakeAlarmScheduler.shared.lastErrorDescription ?? "")
            if outcome == .notAuthorized { behavior.smartWakeEnabled = false }
            if outcome == .enabled { model.applySmartWakeSchedule() }
        }
    }

    /// A tap on a row body: opens the editor, unless it is the tail of a swipe or a row is open (then it only closes).
    private func tapRow(_ alarm: SmartWakeAlarm) {
        switch SmartWakeSwipe.tap(openID: swipeOpenID, lastDragActivity: lastSwipeActivity, now: Date()) {
        case .edit: openEditor(alarm)
        case .close: withAnimation(.easeOut(duration: 0.2)) { swipeOpenID = nil }
        case .ignore: break
        }
    }

    private func openEditor(_ alarm: SmartWakeAlarm) {
        swipeOpenID = nil
        isNew = false
        editing = alarm
    }

    private func delete(_ alarm: SmartWakeAlarm) {
        swipeOpenID = nil
        deleteTick += 1
        store.delete(id: alarm.id)
    }

    private func setEnabled(_ alarm: SmartWakeAlarm, _ on: Bool) {
        var changed = alarm
        changed.isEnabled = on
        attemptSave(changed)
    }

    @discardableResult
    private func attemptSave(_ alarm: SmartWakeAlarm) -> Bool {
        switch store.save(alarm) {
        case .applied: return true
        case let .conflicts(conflicts):
            pending = PendingConflict(alarm: alarm, conflicts: conflicts)
            return false
        case .needsWeekday, .limitReached: return false
        }
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var usualWakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = usualWake / 60
                c.minute = usualWake % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                usualWake = minutes
                WindDownNudge.setWakeMinutes(minutes)
            })
    }

    // MARK: Helpers

    // Fork-table copy held in properties, so the i18n audit (which reads literals inside `.alert(`/`.navigationTitle(`
    // calls against the default catalog) is not asked about strings that live in `Fork.xcstrings`.
    static var conflictTitle: String { ForkCopy.string("Days already taken") }
    static var cancelTitle: String { ForkCopy.string("Cancel") }
    static var notificationsOffTitle: String { ForkCopy.string("Notifications are off") }
    static var openSettingsTitle: String { ForkCopy.string("Open Settings") }
    static var notNowTitle: String { ForkCopy.string("Not now") }
    static var informationTitle: String { ForkCopy.string("Information") }
    static var addTitle: String { ForkCopy.string("Add alarm") }
    static func switchOffTitle(_ names: String) -> String { ForkCopy.string("Switch off \(names) and turn this on") }
    static func nextTitle(_ text: String) -> String { ForkCopy.string("Next: \(text)") }

    private static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private static func timeLabel(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private static var cachedFormatter: (localeID: String, formatter: DateFormatter)?

    /// "Mon 07:20" in the app language; rebuilt only when the language changes (template formatters are costly).
    private static func nextFormatter() -> DateFormatter {
        let locale = AppLanguage.activeLocale
        if let cached = cachedFormatter, cached.localeID == locale.identifier { return cached.formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        cachedFormatter = (locale.identifier, formatter)
        return formatter
    }
}

/// Everything the screen no longer repeats inline, in one sheet.
struct SmartWakeAlarmsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    block("Silent vibration",
                          "The strap alarm is a silent buzz from the strap's own firmware, not a sound. It is armed on the strap, so it can buzz even if the phone is asleep or NOOP is closed.")
                    block("iPhone alarm",
                          "Smart Wake also schedules a system alarm (iOS 26 or later) that can ring through Silent mode and Focus. Its maximum-time alarm stays scheduled even when heart-rate data is missing. Keep your Clock alarm as a backup until you have tested Smart Wake on this iPhone.")
                    block("Earlier wake",
                          "NOOP estimates light sleep from WHOOP heart rate and beat intervals and wakes you earlier inside the window. It is an estimate, not a measured sleep stage.")
                    block("Live Activities",
                          "The ringing iPhone alarm is shown through a Live Activity. With Live Activities off for NOOP, the iPhone alarm stays silent.")
                    block("WHOOP 5.0 and MG",
                          "On a 5.0 or MG the strap alarm is experimental: it only arms with Protocol probes on (Test Centre, 5/MG protocol diagnostics). Strap wakes have been reported but are not guaranteed.")
                    block("Evening reminder",
                          "A calm reminder timed from your usual wake time and your sleep need. It is a suggestion, not an alarm, and the usual wake time does not wake you.")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(verbatim: SmartWakeAlarmsScreen.informationTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { ForkCopy.text("Done") } }
            }
        }
        .tint(StrandPalette.accent)
    }

    private func block(_ title: String.LocalizationValue, _ body: String.LocalizationValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForkCopy.text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            ForkCopy.text(body).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
