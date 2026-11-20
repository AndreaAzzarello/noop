import Foundation
import WhoopStore

/// fork: rules that keep one fact from appearing twice on the Today screens. Pure, so each is tested alone;
/// the screens only ask and render.
enum TodayDedup {

    /// The three scores the rings already show.
    static let ringTiles: Set<KeyMetric> = [.charge, .effort, .rest]
    /// The three overnight vitals the Recovery Vitals card repeats.
    static let vitalTiles: Set<KeyMetric> = [.hrv, .restingHr, .respiratory]

    /// The Key-Metric tiles worth drawing: no ring score while the rings are on screen, and no Blood Oxygen tile
    /// that has nothing to say (the strap never banks it on WHOOP 5.0). Order is kept.
    static func keyMetrics(_ enabled: [KeyMetric], heroVisible: Bool, hasBloodOxygenValue: Bool) -> [KeyMetric] {
        enabled.filter { metric in
            if heroVisible && ringTiles.contains(metric) { return false }
            if metric == .bloodOxygen && !hasBloodOxygenValue { return false }
            return true
        }
    }

    /// The Recovery Vitals card repeats HRV, resting HR and respiration; it is dropped only when the Key Metrics
    /// grid is on screen AND already carries all three. With any of them missing there, the card is the only place.
    static func showsRecoveryVitals(keyMetricsVisible: Bool, shownKeyMetrics: [KeyMetric]) -> Bool {
        !(keyMetricsVisible && vitalTiles.isSubset(of: Set(shownKeyMetrics)))
    }

    /// The "Last workouts" section repeats the workout summary card while today has a workout.
    static func showsLastWorkouts(todaysWorkoutShownAbove: Bool) -> Bool { !todaysWorkoutShownAbove }

    /// Workouts for a recent-activity list, without the ones today's summary card already shows. Only applies while
    /// viewing today, because the card itself only shows then.
    static func excludingToday(_ rows: [WorkoutRow], isViewingToday: Bool, now: Date,
                               calendar: Calendar = .current) -> [WorkoutRow] {
        guard isViewingToday else { return rows }
        let shown = Set(TodayWorkoutSummary.todaysWorkouts(rows, now: now, calendar: calendar).map(\.startTs))
        return rows.filter { !shown.contains($0.startTs) }
    }

    /// The Charge / Effort labels inside the heart-rate chart repeat the rings; they stay only when the rings are hidden.
    static func showsHRChartMarkers(heroVisible: Bool) -> Bool { !heroVisible }
}
