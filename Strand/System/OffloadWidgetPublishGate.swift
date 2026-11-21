import Foundation

/// Decides whether a completed strap offload republishes the Home-screen widget.
///
/// WHY. Every offload published the widget, even one that banked nothing (about every 15 minutes, ~130 reloads a
/// day measured). The filter applies ONLY to an offload that brought nothing new. Anything else that changes what
/// the widget shows still publishes at once, in the background too:
///
/// - the Smart Wake alarm list, its toggle and its schedule publish through `ForkWidgetPublisher.publishSmartWake`
///   from `commitSmartWakeSchedule`, a path this gate is not on;
/// - the next alarm is compared here as well, because it moves on its own when an alarm has rung;
/// - a strap battery at or under the low threshold, whenever it changes.
///
/// Pure value logic, so the table of cases runs in `StrandTests`.
enum OffloadWidgetPublishGate {

    /// What the widget showed at the last publish this gate allowed.
    struct State: Equatable {
        var batteryPct: Int?
        /// Epoch seconds of the next alarm's latest time, nil when none.
        var nextAlarmTs: Int?
        /// `SmartWakeAlarmStore.revision`; 0 where there is no alarm list.
        var alarmListRevision: Int
    }

    enum Reason: Equatable {
        case firstPublish, newData, lowBattery, nextAlarmChanged, alarmListChanged
    }

    /// The strap's low-battery line, the same one `BatteryAlertPolicy` warns at.
    static let lowBatteryThreshold = 15

    /// nil means: skip this publish.
    static func reason(newDataBanked: Bool, last: State?, now: State, lowThreshold: Int = lowBatteryThreshold) -> Reason? {
        guard let last else { return .firstPublish }
        if newDataBanked { return .newData }
        if now.alarmListRevision != last.alarmListRevision { return .alarmListChanged }
        if now.nextAlarmTs != last.nextAlarmTs { return .nextAlarmChanged }
        if let battery = now.batteryPct, battery <= lowThreshold, battery != last.batteryPct { return .lowBattery }
        // Back above the line after being under it: the widget must stop showing the low state.
        if let previous = last.batteryPct, previous <= lowThreshold, let battery = now.batteryPct, battery > lowThreshold {
            return .lowBattery
        }
        return nil
    }
}

/// The state the last allowed publish left, kept in memory: a relaunch publishes once, which is the safe side.
@MainActor
final class OffloadWidgetPublishState {
    static let shared = OffloadWidgetPublishState()
    var last: OffloadWidgetPublishGate.State?
}
