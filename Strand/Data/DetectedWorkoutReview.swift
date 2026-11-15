import Foundation
import WhoopProtocol
import StrandAnalytics

// MARK: - Reviewing a detected workout: time limits and window statistics
//
// Pure logic behind `DetectedWorkoutReviewSheet`. The detector's thresholds are untouched; this only
// decides how far the user may move the start/end of a suggested window and recomputes the window's
// stats from the HR samples. All values are unix SECONDS. No clock, no I/O, no actor isolation.

enum DetectedWorkoutReview {

    /// How far outside the detected window the user may move either edge (a sensible "I warmed up
    /// before the strap noticed" allowance).
    static let slackSec = 30 * 60
    /// Shortest span the review accepts, so the stats and chart stay meaningful.
    static let minSpanSec = 5 * 60
    /// The edited span must still overlap the detected window by at least this much. That keeps the saved
    /// workout excluding the original window from re-suggestion (the detector drops any overlap with a
    /// saved workout) and stops the review drifting off to some unrelated stretch.
    static let overlapMarginSec = 60

    struct Bounds: Equatable {
        let earliest: Int
        let latest: Int
    }

    struct Stats: Equatable {
        let durationMin: Int
        let avgBpm: Int
        let maxBpm: Int
    }

    /// The range both edges must stay within: the detected window ± `slackSec`, never in the future.
    static func bounds(for w: DetectedWorkout, now: Int) -> Bounds {
        Bounds(earliest: w.startSec - slackSec,
               latest: max(min(w.endSec + slackSec, now), w.endSec))
    }

    /// Forces a proposed (start, end) into `bounds`, keeps at least `minSpanSec` between them and keeps
    /// the span overlapping the detected window. Start wins when the span is too short: the end moves.
    static func clamp(start: Int, end: Int, for w: DetectedWorkout, now: Int) -> (start: Int, end: Int) {
        let b = bounds(for: w, now: now)
        var s = min(max(start, b.earliest), w.endSec - overlapMarginSec)
        var e = max(min(end, b.latest), w.startSec + overlapMarginSec)
        if e - s < minSpanSec {
            e = s + minSpanSec
            if e > b.latest {
                e = b.latest
                s = e - minSpanSec
            }
        }
        return (s, e)
    }

    /// Duration, average and peak HR over the samples inside [start, end] (both inclusive). Same rules
    /// as `AutoWorkoutDetector` (rounded mean, floor minutes), so an unedited window shows the numbers
    /// the card showed. nil with fewer than two samples: no honest figures to show.
    static func stats(samples: [HRSample], start: Int, end: Int) -> Stats? {
        let inWindow = samples.filter { $0.ts >= start && $0.ts <= end }
        guard inWindow.count >= 2, end > start else { return nil }
        let bpms = inWindow.map(\.bpm)
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        return Stats(durationMin: (end - start) / 60, avgBpm: avg, maxBpm: bpms.max() ?? avg)
    }
}
