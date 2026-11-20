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
        var efficiency: Double?          // 0...100, as `DailyMetric.efficiency`
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
    }

    let sleepMinutes: Int?
    let bedTs: Int?
    let wakeTs: Int?
    let stages: Stages?
    let efficiencyPct: Int?
    let earlyWakeAt: Date?
    let nextAlarm: NextAlarm?
    /// Latest bedtime that still gives `sleepNeedMinutes` before `nextAlarm.latest`; nil when unknown or past.
    let bedtime: Date?

    var hasSleep: Bool { sleepMinutes != nil }

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

    static func make(_ i: Inputs) -> NightSummary {
        let minutes = i.totalSleepMin.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }

        func whole(_ v: Double?) -> Int { v.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil } ?? 0 }
        let stages = Stages(deepMin: whole(i.deepMin), remMin: whole(i.remMin), lightMin: whole(i.lightMin))

        let efficiency = i.efficiency.flatMap { $0.isFinite && (0...100).contains($0) ? Int($0.rounded()) : nil }
        let next = resolveNextAlarm(smartWake: i.smartWake, strapAlarm: i.strapAlarm, now: i.now)

        return NightSummary(
            sleepMinutes: minutes,
            bedTs: minutes == nil ? nil : i.bedTs,
            wakeTs: minutes == nil ? nil : i.wakeTs,
            stages: minutes != nil && stages.total > 0 ? stages : nil,
            efficiencyPct: minutes == nil ? nil : efficiency,
            earlyWakeAt: minutes == nil ? nil : i.earlyWakeAt,
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
