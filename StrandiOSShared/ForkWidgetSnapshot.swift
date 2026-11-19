import Foundation

// MARK: - Fork widget ("NOOP+") snapshot
//
// Fork-only data the NOOP+ widget needs and the upstream `WidgetSnapshot` does not carry: today's
// heart-rate curve already split into single-zone runs, last night's sleep, and the Smart Wake schedule.
// Kept in its OWN App Group key so `WidgetSnapshot.swift` stays byte-identical to upstream and a merge
// never has to reconcile the two. The app writes it (`ForkWidgetPublisher`); the widget only reads it.

/// One unbroken stretch of today's heart rate that stays inside a single zone (0 = below Zone 1).
/// Adjacent runs of one stretch share their boundary point, so the coloured pieces meet exactly.
struct ForkZoneRun: Codable, Equatable, Sendable {
    let zone: Int
    let points: [HrPoint]
}

/// Today's heart-rate curve, ready to draw: the app resolved the zones, the widget only strokes paths.
struct ForkHRDay: Codable, Equatable, Sendable {
    /// Local day number (`WidgetSnapshot.localDayNumber`) the curve belongs to.
    let day: Int
    /// Timestamp of the newest bucket, for the "up to HH:mm" caption.
    let throughTs: Int64
    /// True extremes of the day (lowest / highest sample, not the 5-minute means the curve is drawn from),
    /// so the min/max readout describes the day rather than the calmest and busiest five minutes (#2032).
    let minBpm: Int
    let maxBpm: Int
    let runs: [ForkZoneRun]
}

/// The next Smart Wake occurrence as the widget shows it.
struct ForkNextWake: Equatable {
    /// Start of the early-wake window; nil when the window is zero-length (only the latest time exists).
    let windowStart: Date?
    /// The latest (maximum) wake time.
    let latest: Date
}

// MARK: - Extra-large extras
//
// Everything below feeds ONLY the extra-large NOOP+ family. Every type carries the local day number it was
// built for, so a block from yesterday is dropped on read instead of shown under today's date, and every
// field of `ForkWidgetSnapshot` that holds one is optional, so a snapshot written by an older build still
// decodes (the generated `Codable` fills a missing optional with nil).

/// Respiratory rate and skin temperature, pre-formatted by the app: the widget extension cannot read the
/// app's unit preferences (they live outside the App Group), the same reason `effortDisplay` is a string.
struct ForkVitals: Codable, Equatable, Sendable {
    let day: Int
    /// "14.2" (breaths per minute); nil when no night within the staleness bound measured one.
    var respText: String?
    /// "34.2 °C" or "+0.1 Δ°C": the number and unit the Today card leads with, so the two never disagree.
    var skinText: String?
}

/// Last night's stage minutes. Absent entirely when the night was HR-only or too sparse to stage.
struct ForkSleepStages: Codable, Equatable, Sendable {
    let day: Int
    let deepMin: Int
    let remMin: Int
    let lightMin: Int
    let efficiencyPct: Int?
}

/// The newest workout that started today.
struct ForkWorkout: Codable, Equatable, Sendable {
    let day: Int
    /// Canonical sport id (drives the SF Symbol through `sportSymbol`).
    let sport: String
    /// Display name, already localised in the app's language.
    let sportName: String
    let startTs: Int64
    let durationMin: Int
    /// Effort on the user's chosen scale, pre-formatted ("11.8" or "62"); nil when the row has none.
    var effortText: String?
    /// True when `effortText` is on WHOOP's 0–21 axis (spoken form only).
    var effortWhoop: Bool?
    var avgHr: Int?
    var maxHr: Int?
    var kcal: Int?
}

/// One day of the 7-day strip, on the 0–100 axis the rings use. Nil = that score does not exist for the day.
struct ForkTrendDay: Codable, Equatable, Sendable {
    var charge: Int?
    var effort: Int?
    var rest: Int?
}

/// The trailing seven calendar days, oldest first, ending on `day` (today).
struct ForkTrend: Codable, Equatable, Sendable {
    let day: Int
    let days: [ForkTrendDay]
}

struct ForkWidgetSnapshot: Codable, Equatable {
    /// WidgetKit kind of the NOOP+ widget. One constant shared by the widget and the reload call.
    static let kind = "NOOPPlusWidget"
    static let storageKey = "noop.fork.widget.snapshot"

    /// A snapshot older than this is shown as such ("data is old").
    static let staleAfter: TimeInterval = 2 * 60 * 60
    /// The publisher refreshes `publishedAt` at least this often while the app runs, so the stale hint
    /// never appears for data the app has just verified to be unchanged. Kept below `staleAfter`.
    static let republishAfter: TimeInterval = 90 * 60

    /// When the app last confirmed this content. Not part of `contentEquals`.
    var publishedAt: Date
    var sleepMin: Int?
    /// Local day number the sleep figure was banked for.
    var sleepDay: Int?
    /// nil = Smart Wake is off.
    var smartWake: SmartWakeSchedule?
    /// Instant up to which today's occurrence is already spent (early wake confirmed). Only set while it
    /// is still in the future; the app resolves it through `SmartWakeFirmwareSkip.armFrom`.
    var smartWakeSkipUntil: Date?
    var hrDay: ForkHRDay?
    /// Publisher gate: day + HR fingerprint + zone set the `hrDay` above was built from. Not rendered.
    var hrFingerprint: String?

    // Extra-large only. All optional (see the block above).
    var vitals: ForkVitals?
    var sleepStages: ForkSleepStages?
    var workout: ForkWorkout?
    var trend: ForkTrend?
    /// Publisher gate for the two blocks that need a database read (`workout`, `trend`). Not rendered.
    var extrasKey: String?

    static var empty: ForkWidgetSnapshot {
        ForkWidgetSnapshot(publishedAt: .distantPast)
    }

    // MARK: Persistence

    static func load(suiteName: String = WidgetSnapshot.suiteName) -> ForkWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(ForkWidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// - Returns: false when the App Group is unavailable or encoding failed (the caller only logs).
    @discardableResult
    func save(suiteName: String = WidgetSnapshot.suiteName) -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: ForkWidgetSnapshot.storageKey)
        return true
    }

    /// Whether `other` would render identically: everything except the confirmation timestamp and the
    /// publisher's own gate.
    func contentEquals(_ other: ForkWidgetSnapshot) -> Bool {
        sleepMin == other.sleepMin
            && sleepDay == other.sleepDay
            && smartWake == other.smartWake
            && smartWakeSkipUntil == other.smartWakeSkipUntil
            && hrDay == other.hrDay
            && vitals == other.vitals
            && sleepStages == other.sleepStages
            && workout == other.workout
            && trend == other.trend
    }

    // MARK: Resolved on read (nothing runs at midnight to tidy the App Group)

    /// Last night's sleep in minutes, only while it belongs to today.
    func sleepMinutes(now: Date, calendar: Calendar = .current) -> Int? {
        guard let sleepMin, sleepMin > 0, sleepDay == WidgetSnapshot.localDayNumber(now, calendar: calendar)
        else { return nil }
        return sleepMin
    }

    /// Today's curve, only while it belongs to today and has something to draw.
    func hrToday(now: Date, calendar: Calendar = .current) -> ForkHRDay? {
        guard let hrDay, hrDay.day == WidgetSnapshot.localDayNumber(now, calendar: calendar),
              hrDay.runs.contains(where: { !$0.points.isEmpty }) else { return nil }
        return hrDay
    }

    // MARK: Extra-large blocks, each only while it belongs to today

    func vitalsToday(now: Date, calendar: Calendar = .current) -> ForkVitals? {
        guard let vitals, vitals.day == WidgetSnapshot.localDayNumber(now, calendar: calendar),
              vitals.respText != nil || vitals.skinText != nil else { return nil }
        return vitals
    }

    func sleepStagesToday(now: Date, calendar: Calendar = .current) -> ForkSleepStages? {
        guard let sleepStages, sleepStages.day == WidgetSnapshot.localDayNumber(now, calendar: calendar),
              sleepStages.deepMin + sleepStages.remMin + sleepStages.lightMin > 0 else { return nil }
        return sleepStages
    }

    func workoutToday(now: Date, calendar: Calendar = .current) -> ForkWorkout? {
        guard let workout, workout.day == WidgetSnapshot.localDayNumber(now, calendar: calendar) else { return nil }
        return workout
    }

    /// The strip, only when today's and when at least one day has any score to draw.
    func trendToday(now: Date, calendar: Calendar = .current) -> ForkTrend? {
        guard let trend, trend.day == WidgetSnapshot.localDayNumber(now, calendar: calendar),
              trend.days.contains(where: { $0.charge != nil || $0.effort != nil || $0.rest != nil }) else { return nil }
        return trend
    }

    /// The next occurrence the widget should announce, or nil when Smart Wake is off.
    ///
    /// Searches from the later of `now` and the recorded skip, so an occurrence that already passed, or
    /// that an early wake already made pointless, is never shown: the NEXT one is. Evaluated at render
    /// time against the entry date, so it stays right between reloads.
    func nextWake(now: Date, calendar: Calendar = .current) -> ForkNextWake? {
        guard let smartWake else { return nil }
        let from = max(now, smartWakeSkipUntil ?? .distantPast)
        guard let latest = smartWake.nextMaximumWakeTime(after: from, calendar: calendar) else { return nil }
        let window = smartWake.windowDuration
        return ForkNextWake(windowStart: window > 0 ? latest.addingTimeInterval(-window) : nil, latest: latest)
    }

    // MARK: Freshness

    /// When the figures on screen were last confirmed, or nil when never.
    func lastUpdate(widget: WidgetSnapshot?) -> Date? {
        let latest = max(widget?.updated ?? .distantPast, publishedAt)
        return latest == .distantPast ? nil : latest
    }

    static func isStale(_ updated: Date, now: Date) -> Bool {
        now.timeIntervalSince(updated) > staleAfter
    }
}

// MARK: - Decimal separator

/// Several figures reach the fork widget already formatted with a "." (upstream helpers print with the C
/// locale). This swaps the separator for the one the given locale uses, touching only a "." with a digit on
/// both sides, so "32.4 °C" becomes "32,4 °C" in Italian and "v1.2.x" style text is left alone.
enum ForkDecimal {
    static func localize(_ text: String, locale: Locale = .current) -> String {
        let separator = locale.decimalSeparator ?? "."
        guard separator != ".", text.contains(".") else { return text }
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == ".", i > 0, i < chars.count - 1, chars[i - 1].isASCII, chars[i - 1].isNumber,
               chars[i + 1].isASCII, chars[i + 1].isNumber {
                out += separator
            } else {
                out.append(c)
            }
        }
        return out
    }
}

// MARK: - Strap battery tiers

/// Battery colour bands, the same cut-offs `DevicesView.batteryTint` uses for the strap battery
/// (below 15 critical, below 35 warning). Restated here because that helper is private to the app
/// target; keep the two in step.
enum ForkBatteryTier: Equatable {
    case normal, warning, critical

    static func tier(forPercent pct: Int) -> ForkBatteryTier {
        pct < 15 ? .critical : pct < 35 ? .warning : .normal
    }
}
