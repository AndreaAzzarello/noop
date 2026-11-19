import Foundation
import WhoopProtocol
import StrandAnalytics

// MARK: - Edge trim for an auto-detected workout
//
// The detector's window starts at the first and ends at the last sample above resting + 30, so a slow
// warm-up or a cool-down tail can add minutes that are not training. This trims both edges until the
// minute-averaged heart rate is *stably* at or above the start of Zone 1, and never touches the middle.
// Pure logic: no clock, no I/O, no actor isolation. `AutoWorkoutDetector` (and its Kotlin twin) are not
// involved; the Repository extension applies this to a candidate the detector already produced.
// All timestamps are unix SECONDS.

enum AutoWorkoutEdgeTrim {

    /// Width of the centred moving average, in one-minute bins.
    static let smoothBins = 3
    /// The smoothed curve must hold the threshold for this many consecutive minutes to count as "stable".
    static let stableBins = 5
    /// Most that may be removed from ONE side. Equal to the review sheet's ±30 min allowance, so the user
    /// can always move an edge back to the detector's original window.
    static let maxTrimPerSideSec = DetectedWorkoutReview.slackSec
    /// Most that may be removed in total, as a share of the detected window (1/2).
    static let maxTotalShareDenominator = 2
    /// Fallback margin over resting HR when no HR max is known: the motion gate's own intensity margin.
    static let fallbackMarginBPM = AutoWorkoutMotionGate.intensityMarginBPM
    /// `UserDefaults` key of the user's custom zone starts, as written by `ProfileStore`.
    static let customZonesKey = "profile.hrZoneThresholds"

    enum Outcome: String, Equatable {
        /// Both edges already sit on stable effort: nothing to remove.
        case unchanged
        /// At least one edge was moved in.
        case trimmed
        /// As `trimmed`, but at least one side hit the per-side limit.
        case capped
        /// The curve never holds the threshold stably: left as detected.
        case noStableRun
        /// Trimming would leave too short a workout, or remove more than half: left as detected.
        case tooShort
    }

    struct Result: Equatable {
        let startSec: Int
        let endSec: Int
        /// Seconds removed at the start / end.
        let headSec: Int
        let tailSec: Int
        let outcome: Outcome
        /// "zone1" when the threshold is the Zone 1 start, "restingMargin" for the fallback.
        let basis: String
    }

    // MARK: Threshold

    /// Where the trimmed workout must stay at or above: the Zone 1 start, but never below the detector's own
    /// elevated floor (resting + 30). Without a Zone 1 start, resting + `fallbackMarginBPM`.
    static func threshold(restingBpm: Int?, zone1Lower: Double?) -> (bpm: Int, basis: String) {
        let resting = restingBpm ?? AutoWorkoutDetector.defaultRestingHR
        guard let zone1Lower, zone1Lower.isFinite, zone1Lower > 0 else {
            return (resting + fallbackMarginBPM, "restingMargin")
        }
        return (max(Int(ceil(zone1Lower)), resting + AutoWorkoutDetector.elevatedMarginBPM), "zone1")
    }

    /// The Zone 1 start of the profile's zones: the custom starts when valid, else a share of HR max. Same
    /// construction as `ProfileStore.hrZoneSet`, so the cut and the chart's "Below Zone 1" agree.
    static func zone1Lower(hrMax: Double?, customLowerBounds: [Double]?) -> Double? {
        guard let hrMax, hrMax.isFinite, hrMax > 0 else { return nil }
        return HRZones.zones(maxHR: hrMax, customLowerBounds: customLowerBounds).zones.first?.lower
    }

    /// The custom zone starts the user saved, or nil when none are stored or they are not valid.
    static func storedCustomLowerBounds(defaults: UserDefaults = .standard) -> [Double]? {
        let values = defaults.string(forKey: customZonesKey)?.split(separator: ",").compactMap { Int($0) } ?? []
        return ProfileStore.validZoneThresholds(values) ? values.map(Double.init) : nil
    }

    // MARK: Trim

    /// Moves `start` and `end` inward to the first and last stable stretch at or above `threshold`.
    /// Returns the original span with the reason when it cannot (or should not) trim.
    static func trim(samples: [HRSample], start: Int, end: Int, threshold: Int,
                     basis: String, minMinutes: Int) -> Result {
        func untouched(_ outcome: Outcome) -> Result {
            Result(startSec: start, endSec: end, headSec: 0, tailSec: 0, outcome: outcome, basis: basis)
        }
        guard end > start else { return untouched(.unchanged) }
        let window = samples.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        guard window.count >= 2 else { return untouched(.noStableRun) }

        // One-minute bins counted from `start`: the mean of each bin's readings, nil when it has none.
        let binCount = (end - start) / 60 + 1
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for s in window {
            let i = min((s.ts - start) / 60, binCount - 1)
            sums[i] += Double(s.bpm)
            counts[i] += 1
        }
        let means: [Double?] = (0..<binCount).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }

        // Centred moving average over the bins that have data; a bin with no data around it is "not above".
        let half = smoothBins / 2
        let above: [Bool] = (0..<binCount).map { i in
            let near = (max(0, i - half)...min(binCount - 1, i + half)).compactMap { means[$0] }
            guard !near.isEmpty else { return false }
            return near.reduce(0, +) / Double(near.count) >= Double(threshold)
        }
        guard binCount >= stableBins else { return untouched(.noStableRun) }

        func stable(endingAt last: Int) -> Bool { (last - stableBins + 1...last).allSatisfy { above[$0] } }
        guard let firstStable = (0...(binCount - stableBins)).first(where: { stable(endingAt: $0 + stableBins - 1) }),
              let lastStableEnd = (stableBins - 1..<binCount).last(where: { stable(endingAt: $0) })
        else { return untouched(.noStableRun) }

        // Per-side limit: cut at most `maxTrimPerSideSec` from either end.
        var headSec = firstStable * 60
        var tailSec = max(0, (end - start) - (lastStableEnd + 1) * 60)
        var capped = false
        if headSec > maxTrimPerSideSec { headSec = maxTrimPerSideSec; capped = true }
        if tailSec > maxTrimPerSideSec { tailSec = maxTrimPerSideSec; capped = true }
        guard headSec > 0 || tailSec > 0 else { return untouched(.unchanged) }

        // Land on real readings: the first one at or after the new start, the last one at or before the new end.
        guard let newStart = window.first(where: { $0.ts >= start + headSec })?.ts,
              let newEnd = window.last(where: { $0.ts <= end - tailSec })?.ts,
              newEnd > newStart
        else { return untouched(.tooShort) }

        let removed = (newStart - start) + (end - newEnd)
        let kept = newEnd - newStart
        guard kept >= minMinutes * 60, removed * maxTotalShareDenominator <= end - start else {
            return untouched(.tooShort)
        }
        return Result(startSec: newStart, endSec: newEnd, headSec: newStart - start, tailSec: end - newEnd,
                      outcome: capped ? .capped : .trimmed, basis: basis)
    }

    /// Whole minutes and enum-like reasons only; no timestamps and no bpm values.
    static func traceLine(_ r: Result) -> String {
        "autoDetect trim headMin=\(r.headSec / 60) tailMin=\(r.tailSec / 60) basis=\(r.basis) result=\(r.outcome.rawValue)"
    }
}
