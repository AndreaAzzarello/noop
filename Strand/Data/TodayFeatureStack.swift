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
    }

    /// First hour of the day at which the Night card turns compact.
    static let compactFromHour = 12

    /// The one answer to "does the detected-workout card show": used by the card itself AND by the ordering, so
    /// the two cannot disagree.
    static func showsDetection(enabled: Bool, handledThisSession: Bool, hasCandidate: Bool) -> Bool {
        enabled && !handledThisSession && hasCandidate
    }

    static func items(showsDetection: Bool, includesDetection: Bool, hasWorkoutToday: Bool,
                      isViewingToday: Bool, now: Date, calendar: Calendar = .current) -> [Item] {
        var out: [Item] = []
        if includesDetection && showsDetection { out.append(.detected) }
        guard isViewingToday else { return out }
        if hasWorkoutToday { out.append(.workout) }
        let compact = calendar.component(.hour, from: now) >= compactFromHour
        out.append(.night(compact ? .compact : .full))
        return out
    }
}
