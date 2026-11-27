import Foundation
import WhoopStore

/// fork: rules that keep one fact from appearing twice on the Today screens. Pure, so each is tested alone;
/// the screens only ask and render.
enum TodayDedup {

    /// The three scores the rings already show.
    static let ringTiles: Set<KeyMetric> = [.charge, .effort, .rest]
    /// The three overnight vitals the Recovery Vitals card repeats.
    static let vitalTiles: Set<KeyMetric> = [.hrv, .restingHr, .respiratory]

    /// The Key-Metric tiles to draw: always 6 or 8, no ring score (the rings show them), order kept. A tile with nothing
    /// to say (Blood Oxygen on WHOOP 5.0) is kept and reads "—", so the grid never falls out of balance.
    static func keyMetrics(_ enabled: [KeyMetric]) -> [KeyMetric] {
        KeyMetricGrid.normalized(enabled)
    }

    /// The Recovery Vitals card repeats HRV, resting HR and respiration; it is dropped only when the Key Metrics
    /// grid is on screen AND already carries all three. With any of them missing there, the card is the only place.
    static func showsRecoveryVitals(keyMetricsVisible: Bool, shownKeyMetrics: [KeyMetric]) -> Bool {
        !(keyMetricsVisible && vitalTiles.isSubset(of: Set(shownKeyMetrics)))
    }

    /// The "Last workouts" section repeats the workout summary card while today has a workout.
    static func showsLastWorkouts(todaysWorkoutShownAbove: Bool) -> Bool { !todaysWorkoutShownAbove }

    /// Workouts for a recent-activity list, without the ones the summary card above already shows for the selected
    /// day (`day`: `now` while viewing today). The card shows them on every day, so the list always drops them.
    static func excludingShown(_ rows: [WorkoutRow], day: Date, now: Date,
                               calendar: Calendar = .current) -> [WorkoutRow] {
        let shown = Set(TodayWorkoutSummary.workouts(rows, onDayOf: day, now: now, calendar: calendar).map(\.startTs))
        return rows.filter { !shown.contains($0.startTs) }
    }

    /// The Charge / Effort labels inside the heart-rate chart repeat the rings; they stay only when the rings are hidden.
    static func showsHRChartMarkers(heroVisible: Bool) -> Bool { !heroVisible }
}
