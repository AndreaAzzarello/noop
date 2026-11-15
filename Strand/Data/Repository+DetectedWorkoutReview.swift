import Foundation
import WhoopProtocol
import StrandAnalytics

// Repository reads/writes for `DetectedWorkoutReviewSheet`. Kept out of Repository.swift so the
// upstream file stays untouched; only internal Repository API is used. No schema change.

extension Repository {

    /// HR samples covering the detected window plus the review slack on both sides, so the user can move
    /// either edge outward and still see data.
    func reviewSamples(for w: DetectedWorkout) async -> [HRSample] {
        let now = Int(Date().timeIntervalSince1970)
        let b = DetectedWorkoutReview.bounds(for: w, now: now)
        return await hrSamples(from: b.earliest, to: b.latest, limit: 50_000)
    }

    /// Saves a reviewed window as a manual-style workout with the chosen sport and edited span. Built
    /// through the same validator as the manual sheet (`buildManualRowFromSpan`), so it persists exactly
    /// like a hand-entered session. Returns false when the validator refuses the span.
    @discardableResult
    func saveReviewedDetectedWorkout(sport: String, start: Date, end: Date, avgHr: Int?) async -> Bool {
        guard let row = WorkoutSource.buildManualRowFromSpan(start: start, end: end, sport: sport,
                                                             avgHr: avgHr, energyKcal: nil) else { return false }
        await saveManualWorkout(row)
        return true
    }
}
