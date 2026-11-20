#if os(iOS)
import Foundation
import UIKit

/// Connects the live heart-rate stream to the Smart Wake detectors, the AlarmKit hand-off and the strap vibration.
///
/// Lives outside `StrandiOSApp` so the app entry keeps a one-line hook. The detector's schedule is built
/// once and rebuilt only when `AppModel.applySmartWakeSchedule()` runs (a change to the wake time,
/// weekdays, per-day overrides or the early window, and every foreground), so the ~1 Hz sample callback
/// no longer decodes the per-day overrides from UserDefaults on every sample. It is the same value the
/// AlarmKit fallbacks are armed from, so the detector and the alarms cannot disagree about the schedule.
@MainActor
enum SmartWakeLiveWiring {
    private static var cachedSchedule: SmartWakeSchedule?
    /// `LiveState.rrSeq` of the last RR packet handed to the controller, so each packet is passed on once.
    private static var lastRRSequence = -1

    /// True while Smart Wake is on and the alarm list has no active alarm (nothing to arm). Read by the next commit to
    /// tell "first alarm switched on again" (needs the enable path) from an ordinary sync.
    private(set) static var hasNoActiveAlarm = false
    private static var scheduleResolved = false

    /// The single place a `SmartWakeSchedule` is built from the user's settings. With Smart Wake on, the alarm list is the
    /// source (nil when it has no active alarm: nothing is armed and the detector stays idle); otherwise it is the
    /// single schedule the Alarms screen holds, exactly as before the list existed.
    static func makeSchedule(from behavior: BehaviorStore) -> SmartWakeSchedule? {
        guard behavior.smartWakeEnabled else { return legacySchedule(from: behavior) }
        return schedule(from: SmartWakeAlarmStore.currentBook(for: behavior))
    }

    /// The alarm list compiled into a schedule; nil without an active alarm.
    static func schedule(from book: SmartWakeAlarmBook) -> SmartWakeSchedule? {
        SmartWakeSchedule.compiled(days: book.effectiveDays().mapValues {
            SmartWakeDaySpec(minutes: $0.minutes, windowMinutes: $0.windowMinutes, label: $0.label, insistent: $0.insistent)
        })
    }

    private static func legacySchedule(from behavior: BehaviorStore) -> SmartWakeSchedule {
        SmartWakeSchedule(
            wakeMinutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            overrides: WindDownNudge.perDayWakeOverrides,
            windowDuration: TimeInterval(behavior.smartWakeWindowMinutes * 60)
        )
    }

    /// Rebuilds the cached schedule and returns it.
    @discardableResult
    static func refreshSchedule(from behavior: BehaviorStore) -> SmartWakeSchedule? {
        let schedule = makeSchedule(from: behavior)
        cachedSchedule = schedule
        scheduleResolved = true
        hasNoActiveAlarm = behavior.smartWakeEnabled && schedule == nil
        return schedule
    }

    /// The RR intervals of the newest packet, or none when it was already passed on (a heart-rate notification
    /// without RR leaves `rrSeq` unchanged). BLEManager publishes the RR just before the heart-rate callback.
    private static func newRR(from live: LiveState) -> [Int] {
        guard live.rrSeq != lastRRSequence else { return [] }
        lastRRSequence = live.rrSeq
        return live.rr
    }

    /// Builds the live controller and feeds it from the model's heart-rate callback.
    static func install(model: AppModel) -> SmartWakeLiveController {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task { @MainActor in SmartWakeAlarmScheduler.shared.startObserving() }
            Task { @MainActor in await SmartWakeTestAlarm.shared.sweep() }
        }
        #endif
        let controller = SmartWakeLiveController(schedule: refreshSchedule(from: model.behavior) ?? .standard)
        let strapAlarm = SmartWakeStrapAlarm(model: model)
        // fork: with an alarm list, insistence is per alarm (the global switch is ignored); without one, it is the global switch.
        strapAlarm.insistentResolver = { maximumWakeTime in
            var bookExists = false
            if case .book = SmartWakeAlarmBookStorage.peek(defaults: .standard) { bookExists = true }
            let weekday = Calendar.current.component(.weekday, from: maximumWakeTime)
            return SmartWakeInsistence.resolve(
                bookExists: bookExists, scheduleSaysInsistent: cachedSchedule?.isInsistent(onWeekday: weekday))
        }
        controller.onWindowSummary = { SmartWakeDiagnostics.record($0) }
        SmartWakeDiagnostics.onRecord = { [weak model] line in model?.live.append(log: AppModel.stamped(line)) }

        // When an early wake-up ends (double tap, or its vibration ran out) the WHOOP firmware alarm must not vibrate
        // again at the maximum time. Record the skip, then re-arm through the existing path, which searches for the
        // next occurrence after it. The re-arm also runs with the firmware alarm off, so nothing stays armed.
        strapAlarm.onEarlyWakeConfirmed = { [weak model] maximumWakeTime in
            guard let model else { return }
            if model.behavior.smartWakeEnabled, model.behavior.smartAlarmEnabled {
                SmartWakeFirmwareSkip.record(skipUntil: maximumWakeTime)
                SmartWakeDiagnostics.record("firmware alarm: this morning's occurrence skipped, next one armed")
            }
            model.applySmartAlarm()
        }

        // Event 57 during a wake-up run belongs to the run: no "smart alarm" notification sound and no re-arm of
        // tomorrow's alarm until the run ends. Outside a run the handler AppModel installed runs as before.
        let existingFirmwareFired = model.live.onSmartAlarmFired
        model.live.onSmartAlarmFired = { [weak strapAlarm] in
            if strapAlarm?.handleFirmwareFired() == true { return }
            existingFirmwareFired?()
        }

        // A strap double tap that ends a wake-up vibration is consumed here; any other tap goes on to the handler
        // AppModel installed (the user's double-tap action, or a Lift Log session's claim).
        let existingDoubleTap = model.live.onDoubleTap
        model.live.onDoubleTap = { [weak strapAlarm] in
            if strapAlarm?.handleDoubleTap() == true { return }
            existingDoubleTap?()
        }

        model.live.onSmartWakeHeartRateSample = { [weak controller, weak model] bpm, timestamp in
            guard let model, model.behavior.smartWakeEnabled else { return }
            if !scheduleResolved { refreshSchedule(from: model.behavior) }
            guard let schedule = cachedSchedule else { return }   // fork: no active alarm, nothing to detect
            controller?.updateSchedule(schedule)
            let decision = controller?.ingest(
                bpm: bpm,
                at: timestamp,
                rr: newRR(from: model.live),
                isForeground: UIApplication.shared.applicationState == .active
            ) ?? .waiting
            strapAlarm.tick(now: timestamp)

            guard case let .wake(reason) = decision, let maximumWakeTime = controller?.maximumWakeTime else { return }
            switch reason {
            case .lightSleep, .sustainedHeartRateRise:
                let label = reason == .lightSleep ? "light sleep" : "heart-rate rise"
                SmartWakeDiagnostics.record("early wake: \(label)")
                // The strap vibrates through its FIRMWARE alarm (armed a moment ahead, silent); the iPhone alarm is only
                // a backup that rings a few minutes later and is cancelled by a double tap. With no usable strap link
                // the iPhone alarm rings straight away, and the weekday's maximum-time alarm stays until a stop.
                let start = strapAlarm.beginEarly(reason: label, maximumWakeTime: maximumWakeTime, at: timestamp)
                if start != .alreadyRan { SmartWakeEarlyWakeRecord.record(at: timestamp) } // Today Night card; write-only
                #if canImport(AlarmKit)
                if #available(iOS 26.0, *), start != .alreadyRan {
                    let viaStrap = start == .started
                    Task {
                        await SmartWakeAlarmScheduler.shared.triggerEarlyWake(
                            at: timestamp, schedule: schedule,
                            alertDelay: viaStrap ? SmartWakeBackupPlan.defaultDelay : 8,
                            keepFallback: viaStrap)
                    }
                }
                #endif
            case .maximumWakeTime:
                strapAlarm.beginAtMaximumTime(maximumWakeTime: maximumWakeTime, at: timestamp)
            }
        }
        // The controller writes its baseline rarely; save the tail when the app is suspended.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            controller?.flushPersistence()
            // A change still waiting for its quiet period would otherwise wait until the app next runs.
            SmartWakeCommitDebouncer.shared.flush()
        }
        return controller
    }
}
#endif
