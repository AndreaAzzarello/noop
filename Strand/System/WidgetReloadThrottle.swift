import Foundation

/// fork: decides whether a changed widget snapshot also asks WidgetKit for a new timeline.
///
/// The heart rate and the strap battery change almost every minute, and each change used to reload every widget:
/// 152 reloads in a day, measured. Those two "live" fields now reload at most once per `liveInterval`; the snapshot is
/// still saved every time, so the next timeline WidgetKit builds on its own reads fresh values. Anything else that
/// changed (a score, the connection, the alarm, the day) reloads at once, and so does a strap battery that crosses the
/// low line in either direction, so the widget never keeps showing a low (or recovered) battery for half an hour.
///
/// Pure value logic, no WidgetKit: the table of cases runs in `StrandTests`.
enum WidgetReloadThrottle {

    /// Longest a live-only change may wait for its reload.
    static let liveInterval: TimeInterval = 30 * 60

    /// The strap's low-battery line, the one `BatteryAlertPolicy` warns at.
    static let lowBatteryThreshold = OffloadWidgetPublishGate.lowBatteryThreshold

    static func crossesLowBattery(previous: Int?, next: Int?, threshold: Int = lowBatteryThreshold) -> Bool {
        guard let previous, let next else { return false }
        return (previous <= threshold) != (next <= threshold)
    }

    /// - `onlyLiveFieldsChanged`: the heart rate and/or the battery moved and nothing else the widget renders did.
    /// - `lastReload`: when this process last asked WidgetKit for a reload (nil: never, so reload).
    static func shouldReload(onlyLiveFieldsChanged: Bool, previousBattery: Int?, nextBattery: Int?,
                             lastReload: Date?, now: Date, interval: TimeInterval = liveInterval) -> Bool {
        guard onlyLiveFieldsChanged else { return true }
        if crossesLowBattery(previous: previousBattery, next: nextBattery) { return true }
        guard let lastReload else { return true }
        return now.timeIntervalSince(lastReload) >= interval || now < lastReload   // a clock that moved back reloads
    }
}
