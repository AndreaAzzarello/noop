import Foundation

/// The instant the WHOOP firmware alarm is armed for DURING a Smart Wake wake-up (an early wake, an insistent
/// repeat or the one-minute test), instead of the user's normal alarm time.
///
/// `AppModel.applySmartAlarm()` re-arms the firmware alarm on every foreground, reconnect and settings change.
/// Without this override that call would put the normal time straight back over a "now + 30 s" arm and the strap
/// would never vibrate. While an override is live, `holdsAlarm` re-sends it instead and tells the caller to stop.
///
/// A stale value can never block the normal alarm: it is honoured only until `staleAfter` past its instant, then
/// it is removed. The session that set it clears it explicitly when the run ends.
enum SmartWakeFirmwareWake {
    static let key = "smartWake.firmwareWakeAt"
    /// How long past its instant an override is still honoured (the strap clock may run a little behind).
    static let staleAfter: TimeInterval = 120
    /// An override further ahead than this is not something a wake-up run could have written.
    static let maximumAhead: TimeInterval = 15 * 60

    static func set(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// The live override instant, or nil (and the value removed) when absent, stale or implausibly far ahead.
    static func current(now: Date = Date(), defaults: UserDefaults = .standard) -> Date? {
        guard let stored = defaults.object(forKey: key) as? Double else { return nil }
        let date = Date(timeIntervalSince1970: stored)
        if now >= date.addingTimeInterval(staleAfter) || date.timeIntervalSince(now) > maximumAhead {
            defaults.removeObject(forKey: key)
            return nil
        }
        return date
    }

    /// True when a wake-up run owns the firmware alarm, so the caller must not arm the normal time. An instant
    /// still in the future is re-sent (a reconnect re-queues the arm); one just passed is left alone.
    static func holdsAlarm(now: Date = Date(), defaults: UserDefaults = .standard, arm: (Date) -> Void) -> Bool {
        guard let date = current(now: now, defaults: defaults) else { return false }
        if date > now { arm(date) }
        return true
    }
}

/// When the iPhone's backup alarm rings after a Smart Wake early wake that the strap is vibrating for.
enum SmartWakeBackupPlan {
    /// Minutes after the early wake at which the iPhone alarm rings if no double tap confirmed the wake-up.
    static let defaultDelay: TimeInterval = 5 * 60

    /// `earlyAt + delay`, or nil when that is not before the maximum wake time (the weekday's maximum-time
    /// alarm already covers it, so a second one would only ring twice).
    static func backupDate(earlyAt: Date, maximumWakeTime: Date, delay: TimeInterval = defaultDelay) -> Date? {
        let date = earlyAt.addingTimeInterval(delay)
        return date < maximumWakeTime ? date : nil
    }
}
