import Foundation

/// Lets the WHOOP firmware alarm skip the occurrence that an early Smart Wake has already made pointless.
///
/// The firmware alarm is one absolute instant, re-armed by `AppModel.applySmartAlarm()` on every foreground, every
/// reconnect and every settings change. After a confirmed early wake, re-arming it for the maximum time of the same
/// morning would make the strap vibrate again. Re-arming it for the NEXT occurrence once is not enough, because the
/// very next `applySmartAlarm()` would put today's instant back; so the skip is remembered here and `applySmartAlarm()`
/// searches for the next occurrence after it instead of after "now".
///
/// It only ever moves the search start forward, for at most 24 hours, and only while Smart Wake is on. With Smart Wake
/// off, or no skip recorded, `armFrom` returns `now` and the firmware alarm behaves exactly as before.
enum SmartWakeFirmwareSkip {
    static let key = "smartWake.firmwareSkipUntil"
    static let maximumSkip: TimeInterval = 24 * 60 * 60

    /// The instant after which `AppModel.nextSmartAlarmDate` should look for the next firmware alarm.
    static func armFrom(now: Date = Date(), smartWakeEnabled: Bool, defaults: UserDefaults = .standard) -> Date {
        guard let stored = defaults.object(forKey: key) as? Double else { return now }
        let skipUntil = Date(timeIntervalSince1970: stored)
        if now >= skipUntil || skipUntil.timeIntervalSince(now) > maximumSkip {
            defaults.removeObject(forKey: key)   // spent, or not something this morning could have recorded
            return now
        }
        return smartWakeEnabled ? skipUntil : now
    }

    /// Skips every firmware occurrence up to and including `skipUntil` (the maximum wake time that was replaced).
    static func record(skipUntil: Date, defaults: UserDefaults = .standard) {
        defaults.set(skipUntil.timeIntervalSince1970, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
