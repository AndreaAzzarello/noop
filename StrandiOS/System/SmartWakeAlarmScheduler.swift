#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

@available(iOS 26.0, *)
private struct SmartWakeAlarmMetadata: AlarmMetadata {}

/// The system-owned maximum-time alarm and the early-wake handoff.
///
/// A separate recurring AlarmKit alarm is kept for each weekday. When Smart Wake detects
/// a valid early trigger, it schedules a one-shot alarm first, then replaces only that
/// weekday's fallback. Dismissing the early alarm re-arms that weekday through its stop intent.
@available(iOS 26.0, *)
@MainActor
final class SmartWakeAlarmScheduler {
    static let shared = SmartWakeAlarmScheduler()

    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard

    private let enabledKey = "smartWake.alarmKit.enabled"
    private let scheduleKey = "smartWake.alarmKit.schedule"
    private let earlyAlarmIDKey = "smartWake.alarmKit.earlyAlarmID"
    private let earlyAlarmWeekdayKey = "smartWake.alarmKit.earlyAlarmWeekday"
    private var updatesTask: Task<Void, Never>?

    private static let fallbackIDs: [Int: UUID] = [
        1: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
        2: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
        3: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
        4: UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!,
        5: UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!,
        6: UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!,
        7: UUID(uuidString: "A1000000-0000-4000-8000-000000000007")!
    ]

    private init() {}

    var isAuthorized: Bool {
        manager.authorizationState == .authorized
    }

    var isConfigured: Bool {
        defaults.bool(forKey: enabledKey) && isAuthorized
    }

    /// Observe the system's alarm list so a dismissed one-shot early alarm restores its
    /// recurring fallback even if the stop intent could not run while the app was suspended.
    func startObserving() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                await self.reconcileEarlyAlarm(with: alarms)
            }
        }
    }

    private func reconcileEarlyAlarm(with alarms: [Alarm]) async {
        guard defaults.bool(forKey: enabledKey),
              let raw = defaults.string(forKey: earlyAlarmIDKey),
              let earlyID = UUID(uuidString: raw),
              let weekday = defaults.object(forKey: earlyAlarmWeekdayKey) as? Int
        else { return }
        guard !alarms.contains(where: { $0.id == earlyID }) else { return }
        await Self.rearmFallback(for: weekday)
    }

    /// Called only after the user explicitly enables Smart Wake.
    func enable(schedule: SmartWakeSchedule) async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        do {
            let authorization: AlarmManager.AuthorizationState
            if manager.authorizationState == .notDetermined {
                authorization = try await manager.requestAuthorization()
            } else {
                authorization = manager.authorizationState
            }
            guard authorization == .authorized else {
                defaults.set(false, forKey: enabledKey)
                await cancelAllManagedAlarms()
                return false
            }

            defaults.set(true, forKey: enabledKey)
            try await replaceFallbacks(with: schedule)
            return true
        } catch {
            defaults.set(false, forKey: enabledKey)
            await cancelAllManagedAlarms()
            return false
        }
    }

    func disable() async {
        defaults.set(false, forKey: enabledKey)
        await cancelAllManagedAlarms()
    }

    /// Reconcile an already-authorized schedule after a settings change or foreground launch.
    /// This method never opens the system authorization prompt.
    func sync(enabled: Bool, schedule: SmartWakeSchedule) async {
        guard #available(iOS 26.0, *) else { return }
        guard enabled else {
            await disable()
            return
        }
        guard manager.authorizationState == .authorized else {
            await disable()
            return
        }
        if defaults.bool(forKey: enabledKey), loadSchedule() == schedule { return }

        defaults.set(true, forKey: enabledKey)
        do {
            try await replaceFallbacks(with: schedule)
        } catch {
            await cancelAllManagedAlarms()
            defaults.set(false, forKey: enabledKey)
            // The existing WHOOP firmware alarm remains untouched.
        }
    }

    /// Called only for a sustained-HR decision, never for the maximum-time detector result.
    func triggerEarlyWake(at receivedAt: Date, schedule: SmartWakeSchedule) async {
        guard #available(iOS 26.0, *),
              defaults.bool(forKey: enabledKey),
              manager.authorizationState == .authorized,
              loadSchedule() == schedule
        else { return }

        let calendar = Calendar.current
        guard let maximumWakeTime = schedule.nextMaximumWakeTime(after: receivedAt, calendar: calendar) else { return }
        let weekday = calendar.component(.weekday, from: maximumWakeTime)
        guard schedule.isEnabled(onWeekday: weekday),
              receivedAt < maximumWakeTime,
              receivedAt >= maximumWakeTime.addingTimeInterval(-schedule.windowDuration),
              let fallbackID = Self.fallbackIDs[weekday]
        else { return }

        let earlyID = UUID()
        let earlySchedule = Alarm.Schedule.fixed(Date().addingTimeInterval(8))
        let configuration = Self.alarmConfiguration(
            schedule: earlySchedule,
            stopIntent: SmartWakeRearmIntent(weekday: weekday)
        )

        do {
            // Schedule first. If this fails, the maximum-time fallback is still armed.
            try await manager.schedule(id: earlyID, configuration: configuration)
            do {
                try await manager.cancel(id: fallbackID)
                defaults.set(earlyID.uuidString, forKey: earlyAlarmIDKey)
                defaults.set(weekday, forKey: earlyAlarmWeekdayKey)
            } catch {
                // Never leave two alarms armed for the same morning.
                try? await manager.cancel(id: earlyID)
            }
        } catch {
            // Keep the maximum-time fallback; early wake is best-effort.
        }
    }

    fileprivate static func rearmFallback(for weekday: Int) async {
        guard #available(iOS 26.0, *),
              (1...7).contains(weekday)
        else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "smartWake.alarmKit.enabled"),
              let data = defaults.data(forKey: "smartWake.alarmKit.schedule"),
              let schedule = try? JSONDecoder().decode(SmartWakeSchedule.self, from: data),
              schedule.isEnabled(onWeekday: weekday),
              let id = fallbackIDs[weekday],
              let localeWeekday = localeWeekday(for: weekday)
        else { return }

        let minutes = schedule.wakeMinutes(onWeekday: weekday)
        let relative = Alarm.Schedule.Relative(
            time: Alarm.Schedule.Relative.Time(hour: minutes / 60, minute: minutes % 60),
            repeats: .weekly([localeWeekday])
        )
        let configuration = alarmConfiguration(schedule: .relative(relative), stopIntent: nil)
        do {
            try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            defaults.removeObject(forKey: "smartWake.alarmKit.earlyAlarmID")
            defaults.removeObject(forKey: "smartWake.alarmKit.earlyAlarmWeekday")
        } catch {
            // The next foreground reconciliation can restore the fallback.
        }
    }

    private func replaceFallbacks(with schedule: SmartWakeSchedule) async throws {
        await cancelAllManagedAlarms()

        let selectedDays = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
        for weekday in selectedDays.sorted() {
            guard let id = Self.fallbackIDs[weekday],
                  let localeWeekday = Self.localeWeekday(for: weekday)
            else { continue }

            let minutes = schedule.wakeMinutes(onWeekday: weekday)
            let relative = Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: minutes / 60, minute: minutes % 60),
                repeats: .weekly([localeWeekday])
            )
            let configuration = Self.alarmConfiguration(
                schedule: .relative(relative),
                stopIntent: nil
            )
            try await manager.schedule(id: id, configuration: configuration)
        }

        if let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: scheduleKey)
        }
    }

    private func cancelAllManagedAlarms() async {
        for id in Self.fallbackIDs.values {
            try? await manager.cancel(id: id)
        }
        if let raw = defaults.string(forKey: earlyAlarmIDKey),
           let id = UUID(uuidString: raw) {
            try? await manager.cancel(id: id)
        }
        defaults.removeObject(forKey: earlyAlarmIDKey)
        defaults.removeObject(forKey: earlyAlarmWeekdayKey)
    }

    private func loadSchedule() -> SmartWakeSchedule? {
        guard let data = defaults.data(forKey: scheduleKey) else { return nil }
        return try? JSONDecoder().decode(SmartWakeSchedule.self, from: data)
    }

    private static func alarmConfiguration(
        schedule: Alarm.Schedule,
        stopIntent: (any LiveActivityIntent)?
    ) -> AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata> {
        let stopButton = AlarmButton(
            text: "Stop",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )
        let alert = AlarmPresentation.Alert(title: "Smart Wake", stopButton: stopButton)
        let attributes = AlarmAttributes<SmartWakeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: SmartWakeAlarmMetadata(),
            tintColor: .orange
        )
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: nil,
            sound: .default
        )
    }

    private static func localeWeekday(for weekday: Int) -> Locale.Weekday? {
        switch weekday {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}

/// Runs when the user dismisses an early Smart Wake alert, restoring the recurring
/// maximum-time fallback for that weekday.
@available(iOS 26.0, *)
public struct SmartWakeRearmIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Restore Smart Wake fallback"

    @Parameter(title: "Weekday")
    public var weekday: Int

    public init(weekday: Int) {
        self.weekday = weekday
    }

    public init() {
        self.weekday = 1
    }

    public func perform() async throws -> some IntentResult {
        await SmartWakeAlarmScheduler.rearmFallback(for: weekday)
        return .result()
    }
}
#endif
