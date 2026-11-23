import Foundation

/// fork: everything the Today "Night" card states, resolved from app data by pure functions.
///
/// Nothing here reads a store: the card gathers the raw figures (`repo.today`, the main-night span, the
/// early-wake record, the next alarm) and hands them to `make`, so every rule is testable without an app.
/// A figure that is not known is nil and the card leaves its line out; no value is ever guessed.
struct NightSummary: Equatable {

    struct Stages: Equatable {
        let deepMin: Int
        let remMin: Int
        let lightMin: Int
        var total: Int { deepMin + remMin + lightMin }
    }

    /// The next time the wearer will be woken, by Smart Wake (a window ending at `latest`) or by the strap alarm.
    struct NextAlarm: Equatable {
        let latest: Date
        /// Start of the Smart Wake window, nil for a plain strap alarm.
        let windowStart: Date?
    }

    /// Raw figures, as stored.
    struct Inputs {
        var totalSleepMin: Double?
        var efficiency: Double?          // 0...100 or 0...1: the strap writes a fraction, imports a percentage
        var deepMin: Double?
        var remMin: Double?
        var lightMin: Double?
        var bedTs: Int?                  // epoch seconds, `SleepView.mainNightSpan(...).start`
        var wakeTs: Int?                 // epoch seconds, `SleepView.mainNightSpan(...).end`
        var earlyWakeAt: Date?           // `SmartWakeEarlyWakeRecord.firedAt(...)`
        var smartWake: NextAlarm?        // nil when Smart Wake is off or has no enabled weekday
        var strapAlarm: Date?            // nil when the strap alarm is off
        var sleepNeedMinutes: Int        // `WindDownNudge.sleepNeedMinutes` (already clamped 300...660)
        var now: Date
        // fork: figures of the fuller card; each is nil when the app does not know it.
        var disturbances: Int? = nil     // `DailyMetric.disturbances`: wake-ups during the night
        var restingHr: Int? = nil        // `DailyMetric.restingHr`: the night's lowest heart rate
        var avgHrv: Double? = nil        // `DailyMetric.avgHrv`, ms
        /// The maximum time of the alarm that woke the wearer early (nil: not recorded, so no "N min early").
        var earlyWakeMaximum: Date? = nil
        /// A wake-up that reached the maximum time with no early wake (nil: not recorded).
        var maximumTimeAt: Date? = nil
    }

    /// How the last Smart Wake ended.
    enum WakeOutcome: Equatable {
        /// `minutesBefore` is nil when the maximum time of that night was not recorded.
        case early(at: Date, minutesBefore: Int?)
        case maximum(at: Date)
    }

    let sleepMinutes: Int?
    let bedTs: Int?
    let wakeTs: Int?
    let stages: Stages?
    let efficiencyPct: Int?
    let earlyWakeAt: Date?
    /// Time in bed not asleep, in minutes; nil under a minute or when the span is unknown.
    let awakeMinutes: Int?
    /// Wake-ups; nil when none were counted.
    let wakings: Int?
    let sleepNeedMinutes: Int
    let restingHr: Int?
    let hrvMs: Int?
    let outcome: WakeOutcome?
    let nextAlarm: NextAlarm?
    /// Latest bedtime that still gives `sleepNeedMinutes` before `nextAlarm.latest`; nil when unknown or past.
    let bedtime: Date?

    var hasSleep: Bool { sleepMinutes != nil }

    /// Asleep minus need, in minutes: negative is a debt, positive a surplus. nil without a sleep total.
    var needDelta: Int? { sleepMinutes.map { $0 - sleepNeedMinutes } }

    // MARK: Rules

    /// `latestWake - need`, and only while it is still ahead of `now`: a bedtime that has passed is not advice.
    /// `latestWake` is the MAXIMUM wake time (the Smart Wake window end, or the strap alarm), so the figure is the
    /// last moment that still guarantees the need, not a target for an early wake.
    static func recommendedBedtime(latestWake: Date?, sleepNeedMinutes: Int, now: Date) -> Date? {
        guard let latestWake else { return nil }
        let bedtime = latestWake.addingTimeInterval(-TimeInterval(sleepNeedMinutes) * 60)
        return bedtime > now ? bedtime : nil
    }

    /// Smart Wake wins when present (its window ends at the maximum time the strap alarm shares); a strap alarm
    /// that is not in the future is not "next".
    static func resolveNextAlarm(smartWake: NextAlarm?, strapAlarm: Date?, now: Date) -> NextAlarm? {
        if let smartWake, smartWake.latest > now { return smartWake }
        if let strapAlarm, strapAlarm > now { return NextAlarm(latest: strapAlarm, windowStart: nil) }
        return nil
    }

    /// Efficiency as a whole percentage. The strap stores a fraction (0.94) and imports a percentage (91): a value
    /// up to 1 is a fraction, the same rule as the watch bridge. 0 and anything outside 0...100 is unknown.
    static func efficiencyPercent(_ raw: Double?) -> Int? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let pct = raw <= 1 ? raw * 100 : raw
        return pct <= 100 ? Int(pct.rounded()) : nil
    }

    /// Minutes in bed that were not sleep: `(wake - bed) - asleep`, only from one minute up.
    static func awakeMinutes(bedTs: Int?, wakeTs: Int?, asleepMinutes: Int?) -> Int? {
        guard let bedTs, let wakeTs, let asleepMinutes, wakeTs > bedTs else { return nil }
        let awake = Int((Double(wakeTs - bedTs) / 60).rounded()) - asleepMinutes
        return awake >= 1 ? awake : nil
    }

    private static func wholeMinute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }

    static func resolveOutcome(earlyWakeAt: Date?, earlyWakeMaximum: Date?, maximumTimeAt: Date?) -> WakeOutcome? {
        if let earlyWakeAt {
            // Whole clock minutes between the two times as the card prints them (07:00:30 → 07:20 is 20, not 19).
            let before = earlyWakeMaximum.map { wholeMinute($0) - wholeMinute(earlyWakeAt) }
            return .early(at: earlyWakeAt, minutesBefore: before.flatMap { $0 >= 1 ? $0 : nil })
        }
        return maximumTimeAt.map { .maximum(at: $0) }
    }

    static func make(_ i: Inputs) -> NightSummary {
        let minutes = i.totalSleepMin.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }

        func whole(_ v: Double?) -> Int { v.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil } ?? 0 }
        let stages = Stages(deepMin: whole(i.deepMin), remMin: whole(i.remMin), lightMin: whole(i.lightMin))

        let efficiency = efficiencyPercent(i.efficiency)
        let next = resolveNextAlarm(smartWake: i.smartWake, strapAlarm: i.strapAlarm, now: i.now)

        return NightSummary(
            sleepMinutes: minutes,
            bedTs: minutes == nil ? nil : i.bedTs,
            wakeTs: minutes == nil ? nil : i.wakeTs,
            stages: minutes != nil && stages.total > 0 ? stages : nil,
            efficiencyPct: minutes == nil ? nil : efficiency,
            earlyWakeAt: minutes == nil ? nil : i.earlyWakeAt,
            awakeMinutes: minutes == nil ? nil : awakeMinutes(bedTs: i.bedTs, wakeTs: i.wakeTs, asleepMinutes: minutes),
            wakings: minutes == nil ? nil : i.disturbances.flatMap { $0 > 0 ? $0 : nil },
            sleepNeedMinutes: i.sleepNeedMinutes,
            restingHr: minutes == nil ? nil : i.restingHr.flatMap { $0 > 0 ? $0 : nil },
            hrvMs: minutes == nil ? nil : i.avgHrv.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil },
            outcome: minutes == nil ? nil
                : resolveOutcome(earlyWakeAt: i.earlyWakeAt, earlyWakeMaximum: i.earlyWakeMaximum, maximumTimeAt: i.maximumTimeAt),
            nextAlarm: next,
            bedtime: recommendedBedtime(latestWake: next?.latest, sleepNeedMinutes: i.sleepNeedMinutes, now: i.now))
    }

    /// Stage shares of the asleep time, in bar order (deep, REM, light). nil without stages.
    var stageShares: [(stage: String, fraction: Double)]? {
        guard let stages, stages.total > 0 else { return nil }
        let total = Double(stages.total)
        return [("deep", Double(stages.deepMin) / total),
                ("rem", Double(stages.remMin) / total),
                ("light", Double(stages.lightMin) / total)]
    }
}

/// fork: the firmware-skip instant, read WITHOUT the side effect `SmartWakeFirmwareSkip.armFrom` has (it deletes a
/// spent value). A display surface must not mutate Smart Wake state, so it reads the same key and applies the same
/// two conditions, leaving the store as it found it.
enum NightSkipPeek {
    static func searchStart(now: Date, smartWakeEnabled: Bool, defaults: UserDefaults = .standard) -> Date {
        guard smartWakeEnabled, let stored = defaults.object(forKey: SmartWakeFirmwareSkip.key) as? Double else { return now }
        let skipUntil = Date(timeIntervalSince1970: stored)
        guard skipUntil > now, skipUntil.timeIntervalSince(now) <= SmartWakeFirmwareSkip.maximumSkip else { return now }
        return skipUntil
    }
}

/// fork: which Night card to show once the clock says "afternoon".
///
/// Before noon the card is full, after it compact (`TodayFeatureStack`). That clock rule alone hid a late arrival: when the
/// night was only processed, or the app only opened, after noon, the first thing the wearer saw of it was the one-line
/// version. A night the card sees for the first time gets the full card for `lateArrivalGrace`, then compact as before.
/// Pure: the card passes in what it persisted and stores the `record` this returns.
enum NightCardStyle {

    /// How long a night that first reached the card after noon keeps the full card.
    static let lateArrivalGrace: TimeInterval = 2 * 3600

    /// The night (its wake day) and the moment the card first showed it with a sleep total.
    struct Seen: Equatable {
        var nightDay: String
        var firstSeenAt: Date
    }

    struct Resolution: Equatable {
        let style: TodayFeatureStack.NightStyle
        /// Non-nil when this load is the first to see the night: persist it.
        let record: Seen?
    }

    static func resolve(requested: TodayFeatureStack.NightStyle, hasSleep: Bool, nightDay: String?,
                        seen: Seen?, now: Date) -> Resolution {
        guard hasSleep, let nightDay else { return Resolution(style: requested, record: nil) }
        guard let seen, seen.nightDay == nightDay else {
            // First sight of this night: it is news, whatever the hour.
            return Resolution(style: .full, record: Seen(nightDay: nightDay, firstSeenAt: now))
        }
        guard requested == .compact else { return Resolution(style: .full, record: nil) }
        let age = now.timeIntervalSince(seen.firstSeenAt)
        // `age >= 0` on purpose: a clock set back must not read as "just arrived" forever.
        return Resolution(style: age >= 0 && age < lateArrivalGrace ? .full : .compact, record: nil)
    }
}
