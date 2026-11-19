import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - Quick edit of a saved workout: the row Save writes
//
// Pure logic behind `WorkoutQuickEditSheet`. It builds the replacement row through the same
// `WorkoutSource.buildManualRowFromSpan` + `preservingCaptured` path `ManualWorkoutSheet` uses, so name, icon
// and calculations follow from the saved row exactly as for a full edit. No clock of its own, no I/O.

enum WorkoutQuickEdit {

    /// The average HR the edited row carries: the stored value while the span is untouched, otherwise the mean
    /// over the new window (the stored value when no readings cover it).
    static func avgHr(row: WorkoutRow, start: Int, end: Int, samples: [HRSample]) -> Int? {
        guard start != row.startTs || end != row.endTs else { return row.avgHr }
        return DetectedWorkoutReview.stats(samples: samples, start: start, end: end)?.avgBpm ?? row.avgHr
    }

    /// The row to save with `replacing: row`, or nil when the span or sport cannot make a valid one (empty
    /// sport, end not after start, a span under a minute or over a day, an end in the future). The sport is
    /// stored as given (the English name or the "Activity" token); distance, calories and the captured
    /// strain / zones / peak HR / steps of an existing session are carried over.
    static func rebuilt(row: WorkoutRow, start: Date, end: Date, sport: String,
                        samples: [HRSample], now: Date = Date()) -> WorkoutRow? {
        let avg = avgHr(row: row, start: Int(start.timeIntervalSince1970), end: Int(end.timeIntervalSince1970),
                        samples: samples)
        guard let base = WorkoutSource.buildManualRowFromSpan(start: start, end: end, sport: sport, avgHr: avg,
                                                              energyKcal: row.energyKcal, distanceM: row.distanceM,
                                                              now: now)
        else { return nil }
        return WorkoutSource.preservingCaptured(base, from: row)
    }
}
