import Foundation

/// How often returning to the foreground runs the full Apple Health sync, and over how many days.
///
/// Each return to the foreground used to read 30 days of aggregates (about 8.6 s) and write back, even when the app had
/// been left a minute earlier. The observers already wake NOOP for new Health samples and re-read the days they touched,
/// so a foreground pass has no news to fetch when it follows closely behind another.
///
/// Rules, in order:
///  - no previous run, the repository not loaded yet, or a clock that moved backwards: run, full window;
///  - another run less than 15 minutes ago, on the same calendar day: skip;
///  - otherwise run. The window is 30 days when the last FULL pass is 24 h old or more, else just the days since the last
///    run (at least 2, so today and yesterday are always read).
///
/// Pure, so the table of cases runs in `StrandTests`. `HealthForegroundSyncState` below is the UserDefaults wrapper.
enum HealthForegroundSyncPolicy {

    struct Plan: Equatable {
        let run: Bool
        let days: Int
        /// True when this pass is the full 30-day one (resets the 24 h clock).
        let isFull: Bool
    }

    static let minInterval: TimeInterval = 15 * 60
    static let fullInterval: TimeInterval = 24 * 3600
    static let fullDays = 30
    static let minDays = 2

    static func decide(now: Date, lastRunAt: Date?, lastFullAt: Date?, repoLoaded: Bool,
                       calendar: Calendar = .current) -> Plan {
        let full = Plan(run: true, days: fullDays, isFull: true)
        guard repoLoaded, let last = lastRunAt else { return full }
        let age = now.timeIntervalSince(last)
        // Wall-clock time can move backwards (NTP, a changed date). A negative age must read as "do not trust".
        guard age >= 0 else { return full }
        let sameDay = calendar.isDate(last, inSameDayAs: now)
        if sameDay, age < minInterval { return Plan(run: false, days: 0, isFull: false) }
        if let fullAt = lastFullAt {
            let fullAge = now.timeIntervalSince(fullAt)
            if fullAge < 0 || fullAge >= fullInterval { return full }
        } else {
            return full
        }
        let start = calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: now)
        let gap = calendar.dateComponents([.day], from: start, to: today).day ?? fullDays
        return Plan(run: true, days: min(fullDays, max(minDays, gap + 1)), isFull: false)
    }
}

/// The two timestamps the policy reads, kept in UserDefaults. Written once per completed pass, never per event.
enum HealthForegroundSyncState {
    static let lastRunKey = "fork.healthFgSync.lastRunAt"
    static let lastFullKey = "fork.healthFgSync.lastFullAt"

    static func plan(repoLoaded: Bool, now: Date = Date(), defaults: UserDefaults = .standard) -> HealthForegroundSyncPolicy.Plan {
        func date(_ key: String) -> Date? {
            (defaults.object(forKey: key) as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        return HealthForegroundSyncPolicy.decide(now: now, lastRunAt: date(lastRunKey), lastFullAt: date(lastFullKey),
                                                 repoLoaded: repoLoaded)
    }

    /// Call only when the sync actually completed: a pass that found the bridge busy must be retried at the next foreground.
    static func recordCompleted(_ plan: HealthForegroundSyncPolicy.Plan, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: lastRunKey)
        if plan.isFull { defaults.set(now.timeIntervalSince1970, forKey: lastFullKey) }
    }
}
