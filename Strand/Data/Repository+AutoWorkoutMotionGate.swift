import Foundation
import WhoopProtocol
import StrandAnalytics

// Repository side of `AutoWorkoutMotionGate`: one motion read over the candidates' span, then the pure verdict
// per candidate. Kept out of Repository.swift so the upstream file only carries the one-line hook. Pure read:
// nothing is written. The detector's output is filtered by the gate, then each survivor's edges are trimmed
// by `AutoWorkoutEdgeTrim`; the detector itself is never changed.

extension Repository {

    /// Keeps the detector candidates that pass the intensity / movement / duration gate, with their edges trimmed
    /// to the stable effort. Returns `candidates` unchanged when there are none. One `autoDetect gate ...` and
    /// one `autoDetect trim ...` trace line per candidate (Test Centre, workouts).
    func gateAutoDetectCandidates(_ candidates: [DetectedWorkout], restingBpm: Int?) async -> [DetectedWorkout] {
        guard let first = candidates.first else { return candidates }
        let settings = AutoWorkoutMotionGate.Settings.load()

        let start = candidates.map(\.startSec).min() ?? first.startSec
        let end = candidates.map(\.endSec).max() ?? first.endSec
        var steps: [StepSample] = []
        var gravity: [GravitySample] = []
        if settings.requireMotion {
            if let store = await storeHandle() {
                for id in importedReadIds {   // active strap FIRST: it wins a shared timestamp in `tally`
                    steps += (try? await store.stepSamples(deviceId: id, from: start, to: end, limit: 200_000)) ?? []
                }
            }
            // A little before the span so the first second's gravity delta and smoothing have a predecessor.
            gravity = await gravitySamplesUnion(from: start - AutoWorkoutMotionGate.gravitySmoothS - 1, to: end)
        }

        var kept: [DetectedWorkout] = []
        for candidate in candidates {
            let tally = settings.requireMotion
                ? AutoWorkoutMotionGate.tally(steps: steps, gravity: gravity,
                                              start: candidate.startSec, end: candidate.endSec)
                : AutoWorkoutMotionGate.Tally(seconds: candidate.endSec - candidate.startSec + 1, covered: 0, moving: 0)
            let evaluation = AutoWorkoutMotionGate.evaluate(candidate, restingBpm: restingBpm,
                                                            tally: tally, settings: settings)
            if TestCentre.active(.workouts), let workoutsLog {
                workoutsLog(AutoWorkoutMotionGate.traceLine(evaluation))
            }
            if evaluation.verdict == .confirmed { kept.append(candidate) }
        }
        return await trimAutoDetectEdges(kept, restingBpm: restingBpm, minMinutes: settings.minMinutes)
    }

    /// Moves each candidate's start and end in to the first and last stable stretch at or above the start of
    /// Zone 1 (never below the detector's elevated floor). One HR read over the candidates' span; if it comes
    /// back empty the candidates are returned as detected. Average, peak and duration are recomputed over the
    /// trimmed window with the review sheet's own rules.
    func trimAutoDetectEdges(_ candidates: [DetectedWorkout], restingBpm: Int?, minMinutes: Int) async -> [DetectedWorkout] {
        guard let first = candidates.first else { return candidates }
        let start = candidates.map(\.startSec).min() ?? first.startSec
        let end = candidates.map(\.endSec).max() ?? first.endSec
        let samples = await hrSamples(from: start, to: end, limit: 200_000)
        guard !samples.isEmpty else { return candidates }

        let zone1 = AutoWorkoutEdgeTrim.zone1Lower(hrMax: strainProfile?.hrMax,
                                                   customLowerBounds: AutoWorkoutEdgeTrim.storedCustomLowerBounds())
        let threshold = AutoWorkoutEdgeTrim.threshold(restingBpm: restingBpm, zone1Lower: zone1)
        return candidates.map { candidate in
            let result = AutoWorkoutEdgeTrim.trim(samples: samples, start: candidate.startSec, end: candidate.endSec,
                                                  threshold: threshold.bpm, basis: threshold.basis,
                                                  minMinutes: minMinutes)
            if TestCentre.active(.workouts), let workoutsLog {
                workoutsLog(AutoWorkoutEdgeTrim.traceLine(result))
            }
            guard result.outcome == .trimmed || result.outcome == .capped,
                  let stats = DetectedWorkoutReview.stats(samples: samples, start: result.startSec, end: result.endSec)
            else { return candidate }
            return DetectedWorkout(startSec: result.startSec, endSec: result.endSec, avgBpm: stats.avgBpm,
                                   peakBpm: stats.maxBpm, durationMin: stats.durationMin)
        }
    }
}
