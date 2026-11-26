import Foundation
import WhoopStore

/// fork: the rules behind the Today "Night" card of a PAST day. Pure: the card reads the stores and hands the
/// figures here, so every rule is testable without an app.
///
/// It is the sleep half of `NightSummary` and nothing else: no alarm, no bedtime, no Smart Wake record. Those
/// are about tonight, and this card must not read any alarm state.
enum PastNight {

    /// A night belongs to the day it ENDED on; this is how far before the day's end a session may still end and
    /// count for it. The same 36 h the live Night card uses, anchored to the selected day instead of to now.
    static let lookbackHours = 36

    /// The sessions that can make up the night that ended on the day starting at `dayStart`.
    static func windowSessions(_ all: [CachedSleepSession], dayStart: Date,
                               calendar: Calendar = .current) -> [CachedSleepSession] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let hi = Int(dayEnd.timeIntervalSince1970)
        let lo = hi - lookbackHours * 3_600
        return all.filter { $0.endTs > lo && $0.endTs <= hi }
    }

    /// Whether the day has a night worth a card: a finite, positive sleep total (the same rule `NightSummary` uses).
    static func hasSleep(_ metric: DailyMetric?) -> Bool {
        guard let total = metric?.totalSleepMin else { return false }
        return total.isFinite && total > 0
    }

    /// The summary of the night in `metric`, bounded by `span` (onset → wake) when the sessions give one.
    /// `nextAlarm`, `bedtime` and `outcome` stay nil by construction.
    static func summary(metric: DailyMetric, span: (start: Int, end: Int)?,
                        sleepNeedMinutes: Int, now: Date) -> NightSummary {
        NightSummary.make(NightSummary.Inputs(
            totalSleepMin: metric.totalSleepMin, efficiency: metric.efficiency,
            deepMin: metric.deepMin, remMin: metric.remMin, lightMin: metric.lightMin,
            bedTs: span?.start, wakeTs: span?.end,
            earlyWakeAt: nil, smartWake: nil, strapAlarm: nil,
            sleepNeedMinutes: sleepNeedMinutes, now: now,
            disturbances: metric.disturbances, restingHr: metric.restingHr, avgHrv: metric.avgHrv))
    }
}
