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

    static func record(at date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    /// The recorded instant, but only when it falls inside the night `[bedTs, wakeTs + grace]` (epoch seconds).
    /// An early wake from another night, or one with no resolvable night, is not stated.
    static func firedAt(inNight bedTs: Int?, wakeTs: Int?, defaults: UserDefaults = .standard) -> Date? {
        guard let bedTs, let wakeTs, let stored = defaults.object(forKey: key) as? Double else { return nil }
        guard stored >= Double(bedTs), stored <= Double(wakeTs) + graceAfterWake else { return nil }
        return Date(timeIntervalSince1970: stored)
    }
}
