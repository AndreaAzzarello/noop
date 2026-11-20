#if os(iOS) && canImport(AlarmKit)
import Foundation
import UIKit

extension AppModel {
    /// Asks for a Smart Wake alarm sync. Requests that arrive in a burst (the time picker fires one per step, and every
    /// foreground, reconnect and settings change asks as well) are merged into ONE commit after 1.5 s without a new one,
    /// or at once when the app goes to the background (`SmartWakeLiveWiring`). Until the commit runs the alarms already
    /// installed stay armed, so waiting never leaves a day uncovered.
    func applySmartWakeSchedule() {
        SmartWakeCommitDebouncer.shared.request { [weak self] in self?.commitSmartWakeSchedule() }
    }

    /// Reconcile the independent phone Smart Wake alarm without touching the WHOOP firmware alarm.
    /// The maximum time, weekdays and per-day overrides are read from the existing alarm settings.
    func commitSmartWakeSchedule() {
        // Also refreshes the schedule the live HR detector reads, so it and the alarms share one value.
        let wasEmpty = SmartWakeLiveWiring.hasNoActiveAlarm
        let schedule = SmartWakeLiveWiring.refreshSchedule(from: behavior)
        // Fork NOOP+ widget: mirror toggle, schedule and any recorded skip (no-op when nothing changed).
        ForkWidgetPublisher.publishSmartWake(from: self, schedule: schedule)
        if #available(iOS 26.0, *) {
            // The sync below is asynchronous and can start just as the app is being suspended: keep the process alive
            // until it has finished. Ended exactly once, by whichever of the two gets there first.
            var background = UIBackgroundTaskIdentifier.invalid
            func endBackgroundTask() {
                guard background != .invalid else { return }
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
            background = UIApplication.shared.beginBackgroundTask(withName: "smartWake.sync") { endBackgroundTask() }
            Task {
                defer { endBackgroundTask() }
                // fork: no active alarm in the list: nothing stays armed (the toggle itself is left as the user set it).
                guard let schedule else {
                    await SmartWakeAlarmScheduler.shared.disable()
                    return
                }
                // fork: the first alarm switched on again after none was active goes through the enable path, which
                // also asks for the Alarms permission if it was never asked.
                if wasEmpty, behavior.smartWakeEnabled, !SmartWakeAlarmScheduler.shared.isConfigured {
                    if await SmartWakeAlarmScheduler.shared.enable(schedule: schedule) == .notAuthorized {
                        behavior.smartWakeEnabled = false
                        ForkWidgetPublisher.publishSmartWake(from: self, schedule: nil)
                    }
                    return
                }
                // The scheduler serializes this behind any in-flight enable (the AlarmKit permission
                // prompt re-activates the scene while enable is still waiting), and reads the toggle
                // only once it runs.
                let outcome = await SmartWakeAlarmScheduler.shared.sync(
                    isEnabled: { [weak self] in self?.behavior.smartWakeEnabled ?? false },
                    schedule: schedule
                )
                // Only an explicit refusal switches the toggle off. A failed update keeps the alarms
                // that are already armed and is retried on the next foreground.
                if outcome == .denied {
                    behavior.smartWakeEnabled = false
                    ForkWidgetPublisher.publishSmartWake(from: self, schedule: schedule)
                }
            }
        }
    }
}
#endif
