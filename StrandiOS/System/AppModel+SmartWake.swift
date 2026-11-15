#if os(iOS) && canImport(AlarmKit)
import Foundation

extension AppModel {
    /// Reconcile the independent phone Smart Wake alarm without touching the WHOOP firmware alarm.
    /// The maximum time, weekdays and per-day overrides are read from the existing alarm settings.
    func applySmartWakeSchedule() {
        // Also refreshes the schedule the live HR detector reads, so it and the alarms share one value.
        let schedule = SmartWakeLiveWiring.refreshSchedule(from: behavior)
        if #available(iOS 26.0, *) {
            Task {
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
                }
            }
        }
    }
}
#endif
