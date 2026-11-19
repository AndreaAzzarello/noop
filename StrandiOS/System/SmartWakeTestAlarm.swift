#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import AppIntents
import Foundation

/// One-minute test of the iPhone alarm (and its Live Activity), armed from the Smart Wake diagnostics.
///
/// Deliberately isolated from Smart Wake's own scheduling:
///  - its own fixed alarm ID, which is neither a weekday fallback (slots A/B) nor the early alarm, so the
///    scheduler's reconcile / sync / disable / stop-from-strap paths, which all work from those ID sets, never
///    see it: nothing of theirs can cancel, re-arm or duplicate it;
///  - it reads and writes no Smart Wake key (schedule, slots, early alarm, skip) and never touches the strap;
///  - it is one-shot, and removed at the latest `lifetime` after it was armed.
/// The configuration (metadata, title, Stop button, tint, sound) comes from the scheduler itself, so the
/// activity is the one real alarms produce.
@available(iOS 26.0, *)
@MainActor
final class SmartWakeTestAlarm {
    static let shared = SmartWakeTestAlarm()

    /// Not one of the `A1…` / `B1…` fallback IDs, and never stored under the early-alarm key.
    static let alarmID = UUID(uuidString: "C1000000-0000-4000-8000-0000000000FF")!
    static let leadTime: TimeInterval = 60
    static let lifetime: TimeInterval = 5 * 60

    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard
    private let deadlineKey = "smartWake.testAlarm.deadline"
    private var watchTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var sawAlerting = false
    private var seenPresent = false

    private init() {}

    private func log(_ message: String) {
        SmartWakeDiagnostics.record("test alarm: \(message)", defaults: defaults)
    }

    private var deadline: Date? {
        defaults.object(forKey: deadlineKey) as? Date
    }

    /// One line for the diagnostics report.
    var statusLine: String {
        guard let deadline, deadline > Date() else { return "Test alarm: none" }
        return "Test alarm: armed, removed by \(deadline.formatted(date: .omitted, time: .standard)) at the latest"
    }

    /// Arms the test and returns the message to show. Never asks for the Alarms permission.
    func arm() async -> String {
        await sweep()
        guard manager.authorizationState == .authorized else {
            return String(localized: "Not started: alarm permission not granted", table: "Fork")
        }
        if deadline != nil {
            return String(localized: "Not started: a test is already running", table: "Fork")
        }
        if let alarms = try? manager.alarms, alarms.contains(where: { alarm in
            if case .alerting = alarm.state { return true }
            return false
        }) {
            return String(localized: "Not started: a NOOP alarm is ringing", table: "Fork")
        }

        let armedAt = Date()
        let fireDate = armedAt.addingTimeInterval(Self.leadTime)
        let expiry = armedAt.addingTimeInterval(Self.lifetime)
        // Recorded before the system call, so a crash in between is still cleaned up by `sweep`.
        defaults.set(expiry, forKey: deadlineKey)
        do {
            try await SmartWakeAlarmScheduler.scheduleTestAlarm(
                id: Self.alarmID, fireDate: fireDate, stopIntent: SmartWakeTestAlarmStopIntent())
        } catch {
            defaults.removeObject(forKey: deadlineKey)
            log("could not be armed: \(error.localizedDescription)")
            return String(localized: "Not started: the system refused the alarm", table: "Fork")
        }
        let clock = fireDate.formatted(date: .omitted, time: .standard)
        log("armed for \(clock) (own ID, not part of the Smart Wake schedule)")
        startWatching(until: expiry)
        return String(localized: "Test alarm armed for \(clock)", table: "Fork")
    }

    /// Launch / diagnostics-open hook: removes an expired or vanished test, resumes watching a live one.
    func sweep() async {
        guard let deadline else { return }
        if deadline <= Date() {
            finish("5-minute limit")
            return
        }
        let present = (try? manager.alarms)?.contains(where: { $0.id == Self.alarmID }) ?? false
        if !present {
            finish("no longer in the system list")
        } else if watchTask == nil {
            startWatching(until: deadline)
        }
    }

    /// The user pressed Stop on the alarm (the stop intent).
    func userStopped() {
        guard deadline != nil else { return }
        log("stopped")
        finish("after Stop")
    }

    private func startWatching(until expiry: Date) {
        sawAlerting = false
        seenPresent = false
        watchTask?.cancel()
        expiryTask?.cancel()
        watchTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self, self.deadline != nil else { return }
                self.handle(alarms)
            }
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    private func handle(_ alarms: [Alarm]) {
        guard deadline != nil else { return }
        if let alarm = alarms.first(where: { $0.id == Self.alarmID }) {
            seenPresent = true
            if case .alerting = alarm.state, !sawAlerting {
                sawAlerting = true
                log("ringing")
            }
        } else if seenPresent {
            // Gone without our intent running (dismissed from the system UI while the app was suspended).
            finish(sawAlerting ? "dismissed" : "removed by the system")
        }
    }

    private func expire() {
        guard deadline != nil else { return }
        finish("5-minute limit")
    }

    /// Idempotent: the deadline key is the "a test exists" flag, so a second call logs nothing.
    private func finish(_ reason: String) {
        guard deadline != nil else { return }
        defaults.removeObject(forKey: deadlineKey)
        watchTask?.cancel()
        expiryTask?.cancel()
        watchTask = nil
        expiryTask = nil
        try? manager.cancel(id: Self.alarmID)
        log("removed (\(reason))")
    }
}

/// Runs when the user presses Stop on the test alarm. Touches only the test alarm.
@available(iOS 26.0, *)
public struct SmartWakeTestAlarmStopIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = LocalizedStringResource("Stop Smart Wake test alarm", table: "Fork")
    public static var isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await SmartWakeTestAlarm.shared.userStopped()
        return .result()
    }
}
#endif
