import Foundation
import WhoopStore

// MARK: - Today workout summary: pure model
//
// The selection and wording behind `TodayWorkoutSummaryCard`. No SwiftUI, no repository, no clock of its
// own (every function takes `now`), so the rules are pinned by `TodayWorkoutSummaryTests` without a strap.
//
// Zone names and the minutes label reuse catalogue keys that already exist (the zone legend of
// `ZoneColoredHRChart`, the "%lld min" label), so no new string is added to the catalogue.

enum TodayWorkoutSummary {

    /// A zone and the whole minutes spent in it.
    struct ZoneHighlight: Equatable {
        let zone: Int
        let minutes: Int
    }

    /// How many zones the one-line summary names at most.
    static let maxHighlights = 2

    /// Workouts that started today (calendar day of `now`) and not after `now`, newest first.
    /// Same "today" rule as `AutoWorkoutCard` (`Calendar.isDateInToday` on the start time).
    static func todaysWorkouts(_ rows: [WorkoutRow], now: Date,
                               calendar: Calendar = .current) -> [WorkoutRow] {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let lo = Int(dayStart.timeIntervalSince1970)
        let hi = Int(dayEnd.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        return rows
            .filter { $0.startTs >= lo && $0.startTs < hi && $0.startTs <= nowTs }
            .sorted { $0.startTs > $1.startTs }
    }

    /// Per-zone minutes for a row, with the same precedence `WorkoutDetailView` applies: the imported
    /// per-workout split (percentages × duration) wins, otherwise the minutes derived from the strap's
    /// samples. Using one rule keeps this card and the detail's HR Zones bar from disagreeing.
    static func zoneMinutes(row: WorkoutRow, derived: [Double]?) -> [Double]? {
        if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 { return pct.map { durMin * $0 / 100.0 } }
        }
        return derived
    }

    /// The zones worth naming: Z1...Z5 with at least one whole minute, the `maxHighlights` busiest
    /// (a tie goes to the higher zone), listed in zone order.
    static func highlights(_ minutes: [Double]) -> [ZoneHighlight] {
        let all = minutes.prefix(5).enumerated().compactMap { index, value -> ZoneHighlight? in
            guard value.isFinite else { return nil }
            let whole = Int(value.rounded())
            return whole >= 1 ? ZoneHighlight(zone: index + 1, minutes: whole) : nil
        }
        let busiest = all.sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.zone > $1.zone }
        return Array(busiest.prefix(maxHighlights)).sorted { $0.zone < $1.zone }
    }

    /// "15 min · Aerobic and 42 min · Threshold". Each piece is minutes + zone name, joined by the
    /// locale's own list conjunction. nil when there is nothing to say.
    static func sentence(_ highlights: [ZoneHighlight],
                         minutesLabel: (Int) -> String = defaultMinutesLabel,
                         zoneName: (Int) -> String = defaultZoneName,
                         locale: Locale) -> String? {
        guard !highlights.isEmpty else { return nil }
        let pieces = highlights.map { "\(minutesLabel($0.minutes)) · \(zoneName($0.zone))" }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: pieces)
    }

    static func defaultMinutesLabel(_ minutes: Int) -> String {
        String(localized: "\(minutes) min")
    }

    /// The names the HR zone legend and the detail bar already use.
    static func defaultZoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        default: return String(localized: "Maximum")
        }
    }

    /// Whether the pencil is offered: manual rows and grandfathered detected bouts only, as in the
    /// Workouts list. Imported history is never edited in place.
    static func isEditable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }
}
