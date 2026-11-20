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

    /// The single place a `SmartWakeSchedule` is built from the user's settings.
    static func makeSchedule(from behavior: BehaviorStore) -> SmartWakeSchedule {
        SmartWakeSchedule(
            wakeMinutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            overrides: WindDownNudge.perDayWakeOverrides,
            windowDuration: TimeInterval(behavior.smartWakeWindowMinutes * 60)
        )
    }

    /// Rebuilds the cached schedule and returns it.
    @discardableResult
    static func refreshSchedule(from behavior: BehaviorStore) -> SmartWakeSchedule {
        let schedule = makeSchedule(from: behavior)
        cachedSchedule = schedule
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
        let controller = SmartWakeLiveController(schedule: refreshSchedule(from: model.behavior))
        let strapAlarm = SmartWakeStrapAlarm(model: model)
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
            let schedule = cachedSchedule ?? refreshSchedule(from: model.behavior)
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
        ) { [weak controller] _ in controller?.flushPersistence() }
        return controller
    }
}
#endif
