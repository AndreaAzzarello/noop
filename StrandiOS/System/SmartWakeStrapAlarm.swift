#if os(iOS)
import Foundation

/// Runs the strap vibration of a Smart Wake wake-up and consumes the double tap that confirms it.
///
/// The schedule itself is the pure `InsistentWakeAlarm`; this class only sends the commands it asks for, ticks it
/// from the ~1 Hz heart-rate callback (which iOS keeps delivering with the phone locked) and from a one-second
/// timer while the app is awake, and turns a strap double tap into "stop the vibration and the iPhone alarm".
///
/// The WHOOP firmware alarm is not touched here: with the insistent option off nothing in this class changes it.
@MainActor
final class SmartWakeStrapAlarm {
    /// UserDefaults key of the "Insistent strap alarm" switch (off by default), shared with the card.
    static let insistentKey = "smartWake.insistentStrapAlarm"
    /// Haptic loops per command. 8 is the most the 5/MG body carries (`MaverickHaptics.notificationBuzz` clamps to
    /// 1...8): the mapped protocol has no intensity field, so a longer, denser train is the strongest effect.
    static let loopsPerCommand: UInt8 = 8

    private weak var model: AppModel?
    private let defaults: UserDefaults
    private var alarm = InsistentWakeAlarm(configuration: .single)
    private var timer: Timer?
    /// Maximum wake time of the morning that already ran: one run per morning, whatever triggers it.
    private var runForMaximumWakeTime: Date?
    /// Set once a single burst is done: a double tap before this time still confirms the wake-up.
    private var awaitingTapUntil: Date?
    /// True while the current run belongs to an early wake (not to the maximum time).
    private var runIsEarly = false
    /// Called once when an early wake-up is confirmed by a double tap, or its repeating vibration runs out.
    /// The argument is the maximum wake time that the early wake replaced.
    var onEarlyWakeConfirmed: ((Date) -> Void)?

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
    }

    var isInsistentEnabled: Bool { defaults.bool(forKey: Self.insistentKey) }

    /// An early wake (light sleep or a sustained rise): always vibrates the strap, once or repeatedly.
    func beginEarly(reason: String, maximumWakeTime: Date, at now: Date) {
        start(reason: reason, maximumWakeTime: maximumWakeTime, at: now,
              configuration: isInsistentEnabled ? .insistent : .single, isEarly: true)
    }

    /// The maximum time was reached with no early wake: only the insistent option vibrates the strap here.
    func beginAtMaximumTime(maximumWakeTime: Date, at now: Date) {
        guard isInsistentEnabled else { return }
        start(reason: "maximum time", maximumWakeTime: maximumWakeTime, at: now, configuration: .insistent, isEarly: false)
    }

    /// Call on every heart-rate sample; sends the command that is due, if any.
    func tick(now: Date) {
        handle(alarm.tick(now: now))
        if let deadline = awaitingTapUntil, now >= deadline { awaitingTapUntil = nil }
        if !alarm.isActive { stopTimer() }
    }

    /// Returns true when the tap was consumed here (it stopped a vibration run or confirmed a wake-up), so the
    /// caller must not also run the user's own double-tap action.
    func handleDoubleTap(now: Date = Date()) -> Bool {
        let result = alarm.doubleTap()
        if result.consumed {
            handle(result.actions)
            stopPhoneAlarm()
            confirmEarlyWake()
            return true
        }
        if let deadline = awaitingTapUntil, now < deadline {
            awaitingTapUntil = nil
            SmartWakeDiagnostics.record("strap double tap confirmed the wake-up")
            stopPhoneAlarm()
            confirmEarlyWake()
            return true
        }
        return false
    }

    // MARK: Private

    /// Reports the confirmation of an early wake once, so the firmware alarm can skip this morning's occurrence.
    private func confirmEarlyWake() {
        guard runIsEarly, let maximumWakeTime = runForMaximumWakeTime else { return }
        runIsEarly = false
        onEarlyWakeConfirmed?(maximumWakeTime)
    }

    private func start(
        reason: String,
        maximumWakeTime: Date,
        at now: Date,
        configuration: InsistentWakeAlarm.Configuration,
        isEarly: Bool
    ) {
        guard runForMaximumWakeTime != maximumWakeTime else { return }
        runForMaximumWakeTime = maximumWakeTime
        runIsEarly = isEarly
        awaitingTapUntil = nil
        alarm = InsistentWakeAlarm(configuration: configuration)
        SmartWakeDiagnostics.record("strap wake-up started (\(reason), \(configuration.repeats ? "repeating" : "single burst"))")
        handle(alarm.start(at: now))
        if alarm.isActive { ensureTimer() }
    }

    private func handle(_ actions: [InsistentWakeAlarm.Action]) {
        for action in actions {
            switch action {
            case let .sendBuzz(burst, index):
                sendBuzz(burst: burst, index: index)
            case let .stopped(reason):
                stopTimer()
                switch reason {
                case .singleBurstDone:
                    awaitingTapUntil = runForMaximumWakeTime
                case .repeatLimit:
                    SmartWakeDiagnostics.record("strap wake-up ended: repeat limit reached without a double tap")
                    confirmEarlyWake()
                case .doubleTap:
                    SmartWakeDiagnostics.record("strap wake-up ended: double tap")
                }
            }
        }
    }

    /// One log line per burst (and any skipped command) so the 50-line diagnostics buffer survives a long run.
    private func sendBuzz(burst: Int, index: Int) {
        guard let model else { return }
        guard model.live.connected, model.live.bonded else {
            SmartWakeDiagnostics.record("strap buzz \(burst + 1).\(index + 1) skipped: strap not connected")
            return
        }
        model.ble.send(.runHapticsPattern, payload: [2, Self.loopsPerCommand, 0, 0, 0], writeType: .withResponse)
        if index == 0 {
            SmartWakeDiagnostics.record("strap buzz burst \(burst + 1) sent")
        }
    }

    private func stopPhoneAlarm() {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task { await SmartWakeAlarmScheduler.shared.stopAlertingAlarms() }
        }
        #endif
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
