import Foundation

/// fork: which of the day's feature cards sit under the Today rings, and in what order.
///
/// A fixed order that reads as a priority: a detected workout waiting for a decision, then today's workout,
/// then the Night card. So a morning without a workout opens with the Night card, a day with a workout puts the
/// workout first and lets the Night card drop below it, and a detected workout goes above both. The Night card is
/// complete before noon and shrinks to one line after it: in the evening what matters is the bedtime, not the
/// breakdown of a night that is half a day old.
enum TodayFeatureStack {

    enum NightStyle: Hashable { case full, compact }

    enum Item: Hashable {
        case detected
        case workout
        case night(NightStyle)
        /// A past day's night: the sleep alone, never an alarm or a bedtime.
        case pastNight
    }

    /// First hour of the day at which the Night card turns compact.
    static let compactFromHour = 12

    /// The one answer to "does the detected-workout card show": used by the card itself AND by the ordering, so
    /// the two cannot disagree.
    static func showsDetection(enabled: Bool, handledThisSession: Bool, hasCandidate: Bool) -> Bool {
        enabled && !handledThisSession && hasCandidate
    }

    /// `hasWorkoutOnDay` is about the SELECTED day: today's workouts while viewing today, that day's otherwise.
    /// A past day has no live Night card (its alarms and bedtime are about tonight): it gets the sleep-only
    /// `.pastNight` when that day has a sleep total (`hasSleepOnDay`, ignored while viewing today).
    static func items(showsDetection: Bool, includesDetection: Bool, hasWorkoutOnDay: Bool, hasSleepOnDay: Bool,
                      isViewingToday: Bool, now: Date, calendar: Calendar = .current) -> [Item] {
        var out: [Item] = []
        if includesDetection && showsDetection { out.append(.detected) }
        if hasWorkoutOnDay { out.append(.workout) }
        guard isViewingToday else {
            if hasSleepOnDay { out.append(.pastNight) }
            return out
        }
        let compact = calendar.component(.hour, from: now) >= compactFromHour
        out.append(.night(compact ? .compact : .full))
        return out
    }
}
