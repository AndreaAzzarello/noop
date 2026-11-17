#if os(iOS)
import Foundation

/// Runs the strap vibration of a Smart Wake wake-up through the WHOOP FIRMWARE alarm and consumes the double tap
/// that confirms it.
///
/// This class NEVER sends a haptic command. Stacking `runHapticsPattern` commands left a WHOOP 5.0 vibrating for
/// over 15 minutes that a double tap could not stop (2026-11-17). Instead it arms the firmware alarm for "now +
/// margin" with the existing `BLEManager.armStrapAlarm`, whose chain (event 57, then 60, dismissed by a double tap)
/// is documented. While a run is live `SmartWakeFirmwareWake` makes `AppModel.applySmartAlarm()` leave that instant
/// alone; when the run ends the override is cleared and the normal alarm is armed again through the existing path.
///
/// The schedule itself is the pure `InsistentWakeAlarm`. It is ticked from the ~1 Hz heart-rate callback (which iOS
/// keeps delivering with the phone locked) and from a one-second timer while the app is awake.
@MainActor
final class SmartWakeStrapAlarm {
    /// UserDefaults key of the "Insistent strap alarm" switch (off by default), shared with the card.
    static let insistentKey = "smartWake.insistentStrapAlarm"
    /// The live instance, for the Diagnostics button.
    static weak var current: SmartWakeStrapAlarm?

    enum Start {
        /// The strap vibration is now armed; the iPhone alarm is only a delayed backup.
        case started
        /// This morning's run already happened; nothing to do.
        case alreadyRan
        /// The firmware alarm cannot be used right now; the iPhone alarm must ring straight away.
        case unavailable
    }

    private weak var model: AppModel?
    private let defaults: UserDefaults
    private var alarm = InsistentWakeAlarm(configuration: .single)
    private var timer: Timer?
    /// Maximum wake time of the morning that already ran: one run per morning, whatever triggers it.
    private var runForMaximumWakeTime: Date?
    /// True while the current run belongs to an early wake (not to the maximum time).
    private var runIsEarly = false
    /// True while the current run is the one-minute test.
    private var runIsTest = false
    /// Called once when an early wake-up ends (double tap, or its vibration ran out). The argument is the maximum
    /// wake time that the early wake replaced. The receiver records the skip and re-arms the normal alarm.
    var onEarlyWakeConfirmed: ((Date) -> Void)?

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        Self.current = self
    }

    var isInsistentEnabled: Bool { defaults.bool(forKey: Self.insistentKey) }

    /// Why the firmware alarm cannot be armed right now, or nil when it can.
    func unusableReason() -> String? {
        guard let model else { return "app model unavailable" }
        guard model.live.connected, model.live.bonded else { return "strap not connected" }
        if model.ble.isWhoop5, !PuffinExperiment.isEnabled { return "5/MG firmware alarm needs Protocol probes" }
        return nil
    }

    /// An early wake (light sleep or a sustained rise): arms the firmware alarm a moment ahead, once or repeatedly.
    func beginEarly(reason: String, maximumWakeTime: Date, at now: Date) -> Start {
        start(reason: reason, maximumWakeTime: maximumWakeTime, at: now,
              configuration: isInsistentEnabled ? .insistent : .single, isEarly: true)
    }

    /// The maximum time was reached with no early wake: only the insistent option repeats the strap alarm here.
    func beginAtMaximumTime(maximumWakeTime: Date, at now: Date) {
        guard isInsistentEnabled else { return }
        _ = start(reason: "maximum time", maximumWakeTime: maximumWakeTime, at: now, configuration: .insistent, isEarly: false)
    }

    /// The Diagnostics button: arms the firmware alarm a minute ahead so the vibration and the double tap can be
    /// checked in daylight. The normal alarm is restored when the test ends. Returns a line for the screen.
    func startTest(at now: Date = Date()) -> String {
        guard !alarm.isActive || runIsTest else { return String(localized: "Not started: a wake-up run is in progress", table: "Fork") }
        if let reason = unusableReason() {
            SmartWakeDiagnostics.record("strap alarm test not started: \(reason)")
            return Self.localizedNotStarted(reason)
        }
        stopTimer()
        alarm = InsistentWakeAlarm(configuration: .test)
        runIsTest = true
        runIsEarly = false
        SmartWakeDiagnostics.record("strap alarm test started")
        handle(alarm.start(at: now))
        ensureTimer()
        return String(localized: "Test started: the strap should vibrate in about a minute. Double-tap it to stop.", table: "Fork")
    }

    /// The on-screen form of an `unusableReason()`. The reason itself stays English: it is also the log line.
    private static func localizedNotStarted(_ reason: String) -> String {
        switch reason {
        case "app model unavailable": return String(localized: "Not started: the app is not ready", table: "Fork")
        case "strap not connected": return String(localized: "Not started: the strap is not connected", table: "Fork")
        case "5/MG firmware alarm needs Protocol probes":
            return String(localized: "Not started: the 5/MG firmware alarm needs Protocol probes", table: "Fork")
        default: return String(localized: "Not started: \(reason)", table: "Fork")
        }
    }

    /// Call on every heart-rate sample; advances the run, if any.
    func tick(now: Date) {
        handle(alarm.tick(now: now))
        if !alarm.isActive { stopTimer() }
    }

    /// Returns true when event 57 belongs to a live run, so the caller must not post the "smart alarm" notification
    /// or re-arm tomorrow's alarm from it; the run does both when it ends.
    func handleFirmwareFired(now: Date = Date()) -> Bool {
        guard alarm.firmwareFired(now: now) else { return false }
        SmartWakeDiagnostics.record("strap alarm fired (event 57), waiting for a double tap")
        return true
    }

    /// Returns true when the tap was consumed here (it ended a run), so the caller must not also run the user's
    /// own double-tap action.
    func handleDoubleTap(now: Date = Date()) -> Bool {
        let result = alarm.doubleTap()
        guard result.consumed else { return false }
        handle(result.actions)
        return true
    }

    // MARK: Private

    private func start(
        reason: String,
        maximumWakeTime: Date,
        at now: Date,
        configuration: InsistentWakeAlarm.Configuration,
        isEarly: Bool
    ) -> Start {
        guard runForMaximumWakeTime != maximumWakeTime else { return .alreadyRan }
        if let why = unusableReason(), isEarly || model?.behavior.smartAlarmEnabled != true {
            // An early wake without a usable firmware alarm hands over to the iPhone alarm at once. A maximum-time
            // run whose firmware alarm is already armed does not need the connection to begin.
            SmartWakeDiagnostics.record("strap wake-up not started (\(reason)): \(why)")
            return .unavailable
        }
        // A real morning always wins over a test that is still waiting.
        if runIsTest { stopTimer(); runIsTest = false }
        runForMaximumWakeTime = maximumWakeTime
        runIsEarly = isEarly
        alarm = InsistentWakeAlarm(configuration: configuration)
        SmartWakeDiagnostics.record("strap wake-up started (\(reason), \(configuration.maximumRepeats > 0 ? "repeating" : "single"))")
        // At the maximum time the firmware alarm is already armed for exactly that instant.
        let alreadyArmed = !isEarly && model?.behavior.smartAlarmEnabled == true
        handle(alarm.start(at: now, firstFireAt: alreadyArmed ? maximumWakeTime : nil))
        ensureTimer()
        return .started
    }

    private func handle(_ actions: [InsistentWakeAlarm.Action]) {
        for action in actions {
            switch action {
            case let .armFirmware(date, attempt):
                SmartWakeFirmwareWake.set(date, defaults: defaults)
                model?.ble.armStrapAlarm(at: date)
                SmartWakeDiagnostics.record("strap alarm armed for \(Self.clock(date)) (\(attempt == 0 ? "first" : "repeat \(attempt)"))")
            case let .firedNotObserved(attempt):
                SmartWakeDiagnostics.record("strap alarm: event 57 not observed for attempt \(attempt + 1); still waiting for a double tap")
            case let .stopped(reason):
                finish(reason)
            }
        }
    }

    /// Ends the run: clears the override, stops what is ringing, restores the normal firmware alarm.
    private func finish(_ reason: InsistentWakeAlarm.StopReason) {
        stopTimer()
        SmartWakeFirmwareWake.clear(defaults: defaults)
        switch reason {
        case .doubleTap: SmartWakeDiagnostics.record("strap wake-up ended: double tap")
        case .repeatLimit: SmartWakeDiagnostics.record("strap wake-up ended: repeat limit reached without a double tap")
        case .expired: SmartWakeDiagnostics.record("strap wake-up ended: no double tap within 5 minutes")
        }

        let wasTest = runIsTest
        let wasEarly = runIsEarly
        let maximumWakeTime = runForMaximumWakeTime
        runIsTest = false
        runIsEarly = false

        if reason == .doubleTap { stopPhoneAndConfirm(maximumWakeTime: wasEarly ? maximumWakeTime : nil) }

        if wasTest {
            SmartWakeDiagnostics.record("strap alarm test ended (\(reason == .doubleTap ? "double tap stopped it" : "no double tap")); normal alarm restored")
            model?.applySmartAlarm()
        } else if wasEarly, let maximumWakeTime {
            onEarlyWakeConfirmed?(maximumWakeTime)
        } else {
            model?.applySmartAlarm()
        }
    }

    /// A double tap stops whatever the iPhone is ringing and, for an early wake, moves the weekday's maximum-time
    /// alarm to next week (the next occurrence is scheduled before today's is removed, so it never passes through zero).
    private func stopPhoneAndConfirm(maximumWakeTime: Date?) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task {
                await SmartWakeAlarmScheduler.shared.stopAlertingAlarms()
                if let maximumWakeTime {
                    await SmartWakeAlarmScheduler.shared.confirmEarlyWakeFromStrap(maximumWakeTime: maximumWakeTime)
                }
            }
        }
        #endif
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(now: Date()) }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
#endif
