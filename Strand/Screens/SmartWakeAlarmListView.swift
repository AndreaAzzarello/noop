#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign

// fork: the Smart Wake alarm list (Apple Clock style) and its editor. Every change goes through `SmartWakeAlarmStore`,
// which enforces "one alarm per weekday", mirrors the upstream settings and asks for ONE debounced sync. The editor
// works on a local draft: nothing is written until Save, and Cancel touches nothing.

/// Weekday and time text shared by the list and the editor, in the app language.
enum SmartWakeAlarmText {
    /// Monday first, as the week reads in Europe; Calendar weekday numbers (1 = Sunday).
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private static func calendar() -> Calendar {
        var calendar = Calendar.current
        calendar.locale = AppLanguage.activeLocale
        return calendar
    }

    static func shortName(_ weekday: Int) -> String { calendar().shortWeekdaySymbols[weekday - 1] }
    static func fullName(_ weekday: Int) -> String { calendar().weekdaySymbols[weekday - 1] }
    static func initial(_ weekday: Int) -> String { calendar().veryShortWeekdaySymbols[weekday - 1] }

    static func time(minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: calendar().date(from: components) ?? Date())
    }

    static func days(_ weekdays: Set<Int>, full: Bool = false) -> String {
        if weekdays.count == 7 { return String(localized: "Every day", table: "Fork") }
        if weekdays == Set(2...6) { return String(localized: "Weekdays", table: "Fork") }
        if weekdays == Set([1, 7]) { return String(localized: "Weekends", table: "Fork") }
        return weekdayOrder.filter { weekdays.contains($0) }.map { full ? fullName($0) : shortName($0) }.joined(separator: " ")
    }

    /// The name an alarm goes by in messages: its label, else its time.
    static func name(of alarm: SmartWakeAlarm) -> String {
        alarm.label.isEmpty ? time(minutes: alarm.wakeMinutes) : alarm.label
    }

    static func summary(of alarm: SmartWakeAlarm) -> String {
        var parts: [String] = []
        if !alarm.label.isEmpty { parts.append(alarm.label) }
        parts.append(days(alarm.weekdays))
        parts.append(String(localized: "\(alarm.windowMinutes) min early", table: "Fork"))
        if alarm.insistent { parts.append(String(localized: "insistent", table: "Fork")) }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for a row: "Work, 7:00 AM, Mon Tue, 30 min early, on".
    static func spoken(_ alarm: SmartWakeAlarm) -> String {
        let state = alarm.isEnabled ? String(localized: "on", table: "Fork") : String(localized: "off", table: "Fork")
        let label = alarm.label.isEmpty ? "" : alarm.label + ", "
        return label + time(minutes: alarm.wakeMinutes) + ", " + days(alarm.weekdays, full: true) + ", "
            + String(localized: "\(alarm.windowMinutes) min early", table: "Fork") + ", " + state
    }
}

/// A refused change waiting for the user's choice.
struct PendingConflict: Identifiable {
    let id = UUID()
    let alarm: SmartWakeAlarm
    let conflicts: [SmartWakeAlarmOverlap.Conflict]
}

struct SmartWakeAlarmListView: View {
    let model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @ObservedObject private var store = SmartWakeAlarmStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SmartWakeAlarm?
    @State private var isNew = false
    @State private var pending: PendingConflict?

    var body: some View {
        NavigationStack {
            List {
                LiveActivitiesNotice().listRowBackground(Color.clear)
                ForEach(store.book.alarms) { alarm in row(alarm) }
                    .listRowBackground(StrandPalette.surfaceRaised)
                if store.book.alarms.isEmpty {
                    Text("No alarms yet. Tap + to add one.", tableName: "Fork")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Text(strapNote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Smart Wake alarms", tableName: "Fork"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Done", tableName: "Fork") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNew = true
                        editing = SmartWakeAlarm(windowMinutes: behavior.smartWakeWindowMinutes)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("Add alarm", tableName: "Fork"))
                }
            }
        }
        .tint(StrandPalette.accent)
        .sheet(item: $editing) { alarm in
            SmartWakeAlarmEditor(original: alarm, isNew: isNew, onSave: { attemptSave($0) }, onDelete: { store.delete(id: $0) })
        }
        .alert(String(localized: "Days already taken", table: "Fork"), isPresented: conflictBinding, presenting: pending) { item in
            Button(String(localized: "Switch off \(Self.names(item.conflicts, in: store.book)) and turn this on", table: "Fork")) {
                store.saveSwitchingOffConflicts(item.alarm)
                editing = nil
            }
            Button(String(localized: "Cancel", table: "Fork"), role: .cancel) {}
        } message: { item in
            Text(Self.conflictMessage(item.conflicts, in: store.book))
        }
        .onAppear { store.attach(behavior: behavior, model: model) }
        .onDisappear { SmartWakeCommitDebouncer.shared.flush() }
    }

    private var strapNote: String {
        behavior.smartAlarmEnabled
            ? String(localized: "The strap vibrates too (strap alarm is on).", table: "Fork")
            : String(localized: "The strap alarm is off: only the iPhone rings.", table: "Fork")
    }

    private func row(_ alarm: SmartWakeAlarm) -> some View {
        SmartWakeAlarmRow(alarm: alarm,
                          onEdit: { isNew = false; editing = alarm },
                          onToggle: { setEnabled(alarm, $0) },
                          onDelete: { store.delete(id: alarm.id) })
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.delete(id: alarm.id) } label: { Text("Delete", tableName: "Fork") }
        }
    }

    private func setEnabled(_ alarm: SmartWakeAlarm, _ on: Bool) {
        var changed = alarm
        changed.isEnabled = on
        attemptSave(changed)
    }

    /// Saves, or asks what to do when the alarm would share a weekday with another active one. Returns whether it saved.
    @discardableResult
    private func attemptSave(_ alarm: SmartWakeAlarm) -> Bool {
        switch store.save(alarm) {
        case .applied: return true
        case let .conflicts(conflicts):
            pending = PendingConflict(alarm: alarm, conflicts: conflicts)
            return false
        case .needsWeekday, .limitReached: return false   // fork: the add button is off at the limit
        }
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    static func names(_ conflicts: [SmartWakeAlarmOverlap.Conflict], in book: SmartWakeAlarmBook) -> String {
        conflicts.map { conflict in
            guard let alarm = book.alarms.first(where: { $0.id == conflict.alarmID }) else { return conflict.label }
            return "«" + SmartWakeAlarmText.name(of: alarm) + "»"
        }.joined(separator: ", ")
    }

    static func conflictMessage(_ conflicts: [SmartWakeAlarmOverlap.Conflict], in book: SmartWakeAlarmBook) -> String {
        let lines = conflicts.map { conflict -> String in
            let name = names([conflict], in: book)
            return String(localized: "\(name) already rings on \(SmartWakeAlarmText.days(conflict.days, full: true)).", table: "Fork")
        }
        return (lines + [String(localized: "Each day can have only one Smart Wake alarm.", table: "Fork")]).joined(separator: "\n")
    }
}

/// The edit sheet. Works on `draft`; the store is only called from Save.
struct SmartWakeAlarmEditor: View {
    let original: SmartWakeAlarm
    let isNew: Bool
    /// Returns true when the change was saved (false: refused, the list shows why).
    let onSave: (SmartWakeAlarm) -> Bool
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartWakeAlarm

    init(original: SmartWakeAlarm, isNew: Bool, onSave: @escaping (SmartWakeAlarm) -> Bool, onDelete: @escaping (UUID) -> Void) {
        self.original = original
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(selection: timeBinding, displayedComponents: .hourAndMinute) {
                        Text("Latest wake time", tableName: "Fork")
                    }
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    if draft.dayOverrides.isEmpty {
                        Text(windowText)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .listRowBackground(StrandPalette.surfaceRaised)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Repeat", tableName: "Fork").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: 8) {
                            ForEach(SmartWakeAlarmText.weekdayOrder, id: \.self) { day in dayChip(day) }
                        }
                        if draft.weekdays.isEmpty {
                            Text("Choose at least one day.", tableName: "Fork")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                    }
                    TextField(text: $draft.label) { Text("Label", tableName: "Fork") }
                        .font(StrandFont.body)
                    Picker(selection: $draft.windowMinutes) {
                        ForEach(SmartWakeAlarm.windowChoices, id: \.self) { Text("\($0) min").tag($0) }
                    } label: { Text("Early window", tableName: "Fork") }
                    Toggle(isOn: $draft.insistent) { Text("Insistent strap alarm", tableName: "Fork") }
                        .tint(StrandPalette.accent)
                    Text("If you don't double-tap the strap, it vibrates again every \(Self.insistentRepeatMinutes) minutes, up to \(Self.insistentRepeatCount) times. A double tap stops it and the iPhone alarm.", tableName: "Fork")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !draft.dayOverrides.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This alarm keeps custom times for some days.", tableName: "Fork")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Button { draft.dayOverrides = [:] } label: { Text("Use one time for every day", tableName: "Fork") }
                        }
                    }
                }
                .listRowBackground(StrandPalette.surfaceRaised)
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            onDelete(original.id)
                            dismiss()
                        } label: { Text("Delete alarm", tableName: "Fork").frame(maxWidth: .infinity) }
                        .foregroundStyle(StrandPalette.statusCritical)
                    }
                    .listRowBackground(StrandPalette.surfaceRaised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(isNew ? "New alarm" : "Edit alarm", tableName: "Fork"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel", tableName: "Fork") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if onSave(draft) { dismiss() }
                    } label: { Text("Save", tableName: "Fork") }
                    .disabled(draft.weekdays.isEmpty)
                }
            }
        }
        .tint(StrandPalette.accent)
        .presentationDetents([.large])
    }

    /// The repeat figures come from the schedule itself, so the text cannot drift from what the strap does.
    private static var insistentRepeatMinutes: Int { Int(InsistentWakeAlarm.Configuration.insistent.repeatInterval / 60) }
    private static var insistentRepeatCount: Int { InsistentWakeAlarm.Configuration.insistent.maximumRepeats }

    private var windowText: String {
        let end = draft.wakeMinutes
        let start = ((end - draft.windowMinutes) % 1440 + 1440) % 1440
        return String(localized: "Rings between \(SmartWakeAlarmText.time(minutes: start)) and \(SmartWakeAlarmText.time(minutes: end)).", table: "Fork")
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: draft.wakeMinutes / 60, minute: draft.wakeMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                draft.wakeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    private func dayChip(_ day: Int) -> some View {
        let selected = draft.weekdays.contains(day)
        return Button {
            if selected { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
        } label: {
            Text(SmartWakeAlarmText.initial(day))
                .font(StrandFont.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(SmartWakeAlarmText.fullName(day)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if DEBUG
#Preview("Alarm editor") {
    SmartWakeAlarmEditor(
        original: SmartWakeAlarm(label: "Work", wakeMinutes: 7 * 60, weekdays: [2, 3, 4, 5, 6], windowMinutes: 30, insistent: true),
        isNew: false, onSave: { _ in true }, onDelete: { _ in })
}
#endif
#endif
