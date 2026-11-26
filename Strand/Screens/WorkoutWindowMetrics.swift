import Foundation
import WhoopStore

// MARK: - Workout detail: extra readouts for the session window
//
// What `WorkoutDetailView` adds to its stat grid beyond duration / HR / calories / distance:
//
//  - an Effort tile, read from `WorkoutRow.strain` (the value the Effort card further down the screen
//    shows), formatted by the same `UnitFormatter.effortDisplay`, so the two cannot disagree;
//  - a Steps tile for the court and field sports. On-foot sports keep the tile `WorkoutDetailView` has
//    always shown (#398); this adds the sports it skips (tennis, padel, football, ...), where the strap
//    or the phone still counted steps during the session.
//
// Nothing is estimated here. A figure with no source is nil and its tile is not drawn: no placeholder
// dash, never a zero. Pure functions, no SwiftUI, so `WorkoutWindowMetricsTests` pins every rule
// without a strap.

enum WorkoutWindowMetrics {

    // MARK: Steps

    enum StepSource: Equatable {
        /// Per-session count carried by an imported activity file (#1058).
        case imported
        /// The strap's own step counter (WHOOP MG / 5.0), scaled by the per-user ticks-per-step.
        case strap
        /// The phone pedometer.
        case phone
    }

    struct Steps: Equatable {
        let count: Int
        let source: StepSource
    }

    /// Court and field sports that get a Steps tile. Catalogue names (`WorkoutCatalog.all`); matching
    /// is case-insensitive and whitespace-trimmed, like `WorkoutCatalog.isOnFoot`.
    static let courtStepSports: Set<String> = [
        "Tennis", "Padel", "Squash", "Badminton", "Pickleball", "Table tennis",
        "Soccer", "Basketball", "Volleyball", "Handball", "Rugby", "Field hockey", "Lacrosse",
    ]

    /// True for a court/field sport that is not an on-foot sport, so a session never carries two Steps
    /// tiles (the on-foot tile belongs to `WorkoutDetailView`).
    static func showsCourtSteps(sport: String) -> Bool {
        guard !WorkoutCatalog.isOnFoot(sport) else { return false }
        let q = sport.trimmingCharacters(in: .whitespaces)
        return courtStepSports.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Picks the step count to show: the imported per-session count first (it is the file's own figure),
    /// then the strap counter, then the phone. A source that is missing, zero or negative is skipped, so
    /// an empty window resolves to nil instead of a fabricated 0. The strap's ticks are divided by the
    /// user's calibration with the same 0.5 floor `WorkoutDetailView` applies to the on-foot tile.
    static func resolveSteps(imported: Int?, strapTicks: Int?, ticksPerStep: Double,
                             pedometer: Int?) -> Steps? {
        if let imported, imported > 0 { return Steps(count: imported, source: .imported) }
        if let strapTicks, strapTicks > 0 {
            let scaled = Int((Double(strapTicks) / max(ticksPerStep, 0.5)).rounded())
            if scaled > 0 { return Steps(count: scaled, source: .strap) }
        }
        if let pedometer, pedometer > 0 { return Steps(count: pedometer, source: .phone) }
        return nil
    }

    // MARK: Estimated distance (display only)
    //
    // The strap has no GPS. For sports where walking or running dominates, distance is estimated as
    // steps x stride length. Never stored, never written to Health, never part of the backup: it is a
    // readout, so it has no Android twin obligation. Expected error: about 15-20% for walk/run,
    // 25-35% for racket and field sports.

    struct DistanceEstimate: Equatable {
        let meters: Double
        let stepLengthM: Double
        let cadenceSpm: Double
    }

    static let racketSports: Set<String> = ["Tennis", "Padel", "Squash", "Badminton", "Pickleball"]
    static let fieldSports: Set<String> = ["Soccer", "Basketball", "Handball", "Rugby", "Field hockey", "Lacrosse"]

    /// Sports that may show an estimated distance: on-foot, racket and field sports. Table tennis and
    /// volleyball are left out (steps are close to in place), as is everything with no footfalls.
    static let distanceEstimateSports: Set<String> =
        WorkoutCatalog.onFootSportNames.union(racketSports).union(fieldSports)

    static func supportsDistanceEstimate(sport: String) -> Bool {
        let q = sport.trimmingCharacters(in: .whitespaces)
        return distanceEstimateSports.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }

    static let walkStrideFactor = 0.415
    static let runStrideFactor = 0.55
    static let racketStrideFactor = 0.35
    static let fallbackHeightCm = 170.0   // same fallback as `estimateBoutCalories`

    /// Estimated distance for a session, or nil when it would not be trustworthy: unsupported sport, a
    /// recorded distance exists (it wins, so two readouts cannot disagree), fewer than 500 steps, a
    /// window under 5 minutes, cadence outside 50...220 steps/min, or a result under 200 m.
    static func estimateDistance(sport: String, steps: Int, durationS: Double, avgHr: Int?,
                                 hrMax: Double, heightCm: Double,
                                 recordedDistanceM: Double?) -> DistanceEstimate? {
        guard supportsDistanceEstimate(sport: sport) else { return nil }
        if let recordedDistanceM, recordedDistanceM > 0 { return nil }
        guard steps >= 500, durationS.isFinite, durationS >= 300 else { return nil }
        let cadence = Double(steps) / (durationS / 60.0)
        guard cadence >= 50, cadence <= 220 else { return nil }

        let height = (heightCm.isFinite && heightCm >= 120 && heightCm <= 220) ? heightCm : fallbackHeightCm
        let q = sport.trimmingCharacters(in: .whitespaces)
        let isRacket = racketSports.contains { $0.caseInsensitiveCompare(q) == .orderedSame }

        let factor: Double
        if isRacket {
            factor = racketStrideFactor
        } else if let avgHr, hrMax > 0, Double(avgHr) < 0.6 * hrMax {
            factor = walkStrideFactor
        } else {
            let t = min(max((cadence - 120) / 30, 0), 1)
            factor = walkStrideFactor + t * (runStrideFactor - walkStrideFactor)
        }
        let stride = height / 100.0 * factor
        let meters = Double(steps) * stride
        guard meters >= 200 else { return nil }
        return DistanceEstimate(meters: meters, stepLengthM: stride, cadenceSpm: cadence)
    }

    // MARK: Effort

    struct Effort: Equatable {
        /// The stored 0-100 value on the selected scale, one decimal.
        let value: String
        let scale: EffortScale
    }

    /// The session's Effort for the stat grid; nil when the row carries none (or a non-finite one).
    static func effort(strain: Double?, scale: EffortScale) -> Effort? {
        guard let strain, strain.isFinite else { return nil }
        return Effort(value: UnitFormatter.effortDisplay(strain, scale: scale), scale: scale)
    }

    // MARK: Loading

    /// Steps for a court/field session. Sources are asked in precedence order and the next one is only
    /// queried when the previous gave nothing (the phone query can raise the Motion permission prompt).
    /// nil for any other sport.
    static func loadCourtSteps(row: WorkoutRow, repo: Repository, ticksPerStep: Double) async -> Steps? {
        guard showsCourtSteps(sport: row.sport) else { return nil }
        if let found = resolveSteps(imported: row.steps, strapTicks: nil, ticksPerStep: ticksPerStep,
                                    pedometer: nil) { return found }
        let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs)
        if let found = resolveSteps(imported: nil, strapTicks: ticks, ticksPerStep: ticksPerStep,
                                    pedometer: nil) { return found }
        let phone = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs)
        return resolveSteps(imported: nil, strapTicks: nil, ticksPerStep: ticksPerStep, pedometer: phone)
    }
}
