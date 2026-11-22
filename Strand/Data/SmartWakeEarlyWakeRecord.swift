import Foundation

/// fork: remembers WHEN the last Smart Wake early wake started, so the Today "Night" card can say
/// "Early wake at 06:56".
///
/// Nothing structured held this before: `SmartWakeDiagnostics` only keeps text lines, and the scheduler's
/// early keys carry an ID and a weekday, not a time. This is a write-only side record: it never feeds back
/// into scheduling, stop or skip, it is only read by the card.
enum SmartWakeEarlyWakeRecord {
    static let key = "smartWake.earlyWake.lastFiredAt"
    /// An early wake can end the night's sleep session a little after it fires (the wearer lies in for a
    /// moment); anything later than this after the wake time is not part of that night.
    static let graceAfterWake: TimeInterval = 30 * 60

    /// fork: the maximum time of the alarm an early wake belongs to, so the card can say "N min early".
    static let maximumKey = "smartWake.earlyWake.maximumWakeTime"
    /// fork: when a wake-up reached the maximum time with no early wake.
    static let maximumTimeKey = "smartWake.maximumTime.firedAt"

    static func record(at date: Date, maximumWakeTime: Date? = nil, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
        // fork: always rewritten with the instant, so a maximum from an earlier night never pairs with this one
        if let maximumWakeTime {
            defaults.set(maximumWakeTime.timeIntervalSince1970, forKey: maximumKey)
        } else {
            defaults.removeObject(forKey: maximumKey)
        }
    }

    /// fork: the wake-up reached the maximum time (no early wake).
    static func recordMaximumTime(at date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: maximumTimeKey)
    }

    /// fork: the maximum time stored with the early wake, under the same night rule as `firedAt`.
    static func maximumWake(inNight bedTs: Int?, wakeTs: Int?, defaults: UserDefaults = .standard) -> Date? {
        guard firedAt(inNight: bedTs, wakeTs: wakeTs, defaults: defaults) != nil,
              let stored = defaults.object(forKey: maximumKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    /// fork: the maximum-time wake-up, only when it falls inside the night `[bedTs, wakeTs + grace]`.
    static func maximumTimeAt(inNight bedTs: Int?, wakeTs: Int?, defaults: UserDefaults = .standard) -> Date? {
        guard let bedTs, let wakeTs, let stored = defaults.object(forKey: maximumTimeKey) as? Double else { return nil }
        guard stored >= Double(bedTs), stored <= Double(wakeTs) + graceAfterWake else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    /// The recorded instant, but only when it falls inside the night `[bedTs, wakeTs + grace]` (epoch seconds).
    /// An early wake from another night, or one with no resolvable night, is not stated.
    static func firedAt(inNight bedTs: Int?, wakeTs: Int?, defaults: UserDefaults = .standard) -> Date? {
        guard let bedTs, let wakeTs, let stored = defaults.object(forKey: key) as? Double else { return nil }
        guard stored >= Double(bedTs), stored <= Double(wakeTs) + graceAfterWake else { return nil }
        return Date(timeIntervalSince1970: stored)
    }
}
