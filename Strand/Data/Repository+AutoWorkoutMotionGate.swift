import Foundation
import WhoopProtocol
import StrandAnalytics

// Repository side of `AutoWorkoutMotionGate`: one motion read over the candidates' span, then the pure verdict
// per candidate. Kept out of Repository.swift so the upstream file only carries the one-line hook. Pure read:
// nothing is written and the detector's output is only ever filtered, never altered.

extension Repository {

    /// Keeps the detector candidates that pass the intensity / movement / duration gate. Returns `candidates`
    /// unchanged when there are none. One `autoDetect gate ...` trace line per candidate (Test Centre, workouts).
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
        return kept
    }
}
