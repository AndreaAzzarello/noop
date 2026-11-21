#if os(iOS)
import Foundation

extension AppModel {
    /// fork-perf: whether the offload that just completed republishes the Home-screen widget.
    ///
    /// Only an offload that banked nothing new is filtered (`OffloadWidgetPublishGate`). The Smart Wake alarm list, the
    /// next alarm and a low strap battery still publish at once. The rule lives in the pure gate; this reads its inputs.
    func shouldPublishWidgetAfterOffload(newDataBanked: Bool) -> Bool {
        let state = OffloadWidgetPublishState.shared
        let now = OffloadWidgetPublishGate.State(
            batteryPct: live.batteryPct.map { Int($0.rounded()) },
            nextAlarmTs: nextSmartWakeAlarmTs(),
            alarmListRevision: smartWakeAlarmListRevision())
        guard OffloadWidgetPublishGate.reason(newDataBanked: newDataBanked, last: state.last, now: now) != nil else {
            ForkEnergyCounters.shared.note(.widgetPublishSkipped)
            return false
        }
        state.last = now
        return true
    }

    private func nextSmartWakeAlarmTs() -> Int? {
        #if canImport(AlarmKit)
        guard behavior.smartWakeEnabled, let schedule = SmartWakeLiveWiring.makeSchedule(from: behavior),
              let next = schedule.nextMaximumWakeTime(after: Date(), calendar: .current) else { return nil }
        return Int(next.timeIntervalSince1970)
        #else
        return nil
        #endif
    }

    private func smartWakeAlarmListRevision() -> Int {
        #if canImport(AlarmKit)
        return SmartWakeAlarmStore.shared.revision
        #else
        return 0
        #endif
    }
}
#endif
