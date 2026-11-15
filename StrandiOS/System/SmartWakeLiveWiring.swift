#if os(iOS)
import Foundation
import UIKit

/// Connects the live heart-rate stream to the Smart Wake detector and AlarmKit hand-off.
///
/// Lives outside `StrandiOSApp` so the app entry keeps a one-line hook. The detector's schedule is built
/// once and rebuilt only when `AppModel.applySmartWakeSchedule()` runs (a change to the wake time,
/// weekdays, per-day overrides or the early window, and every foreground), so the ~1 Hz sample callback
/// no longer decodes the per-day overrides from UserDefaults on every sample. It is the same value the
/// AlarmKit fallbacks are armed from, so the detector and the alarms cannot disagree about the schedule.
enum SmartWakeLiveWiring {
    private static var cachedSchedule: SmartWakeSchedule?

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

    /// Builds the live controller and feeds it from the model's heart-rate callback.
    static func install(model: AppModel) -> SmartWakeLiveController {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            Task { @MainActor in SmartWakeAlarmScheduler.shared.startObserving() }
        }
        #endif
        let controller = SmartWakeLiveController(schedule: refreshSchedule(from: model.behavior))
        controller.onWindowSummary = { SmartWakeDiagnostics.record($0) }
        SmartWakeDiagnostics.onRecord = { [weak model] line in model?.live.append(log: AppModel.stamped(line)) }
        model.live.onSmartWakeHeartRateSample = { [weak controller, weak model] bpm, timestamp in
            guard let model, model.behavior.smartWakeEnabled else { return }
            let schedule = cachedSchedule ?? refreshSchedule(from: model.behavior)
            controller?.updateSchedule(schedule)
            let decision = controller?.ingest(bpm: bpm, at: timestamp, isForeground: UIApplication.shared.applicationState == .active) ?? .waiting
            #if canImport(AlarmKit)
            if case .wake(.sustainedHeartRateRise) = decision, #available(iOS 26.0, *) {
                Task {
                    await SmartWakeAlarmScheduler.shared.triggerEarlyWake(at: timestamp, schedule: schedule)
                }
            }
            #endif
        }
        // The controller writes its baseline rarely; save the tail when the app is suspended.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak controller] _ in controller?.flushPersistence() }
        return controller
    }
}
#endif
