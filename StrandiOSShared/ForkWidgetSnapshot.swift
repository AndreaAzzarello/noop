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
