import Foundation
import WhoopProtocol
import StrandAnalytics

// AutoWorkoutMotionGate.swift — confirmation step between `AutoWorkoutDetector` and the Today card.
//
// The detector alone proposes any ≥ 12 min stretch at HR ≥ resting + 30, which on a low resting HR is
// ordinary moving around. This gate asks for what a sports-tracker style auto-detect asks for: a long enough
// stretch, a high enough AVERAGE intensity, and a share of it spent actually moving. It filters suggestions
// only; the detector, its Kotlin twin, stored data and daily scores are untouched, so there is no cross-platform
// data to keep byte-identical.
//
// Calibrated on 11 days of real data (8 with 5/MG motion, 8 logged workouts): 23 detector windows, 7 of them
// logged workouts. average HR >= resting + 45 and moving >= 20% and >= 15 min keeps 7/7 workouts and 8 windows.
// A movement share alone loses real sessions (karate logs 21-39%); the gravity delta marks 17-79% of every window
// and does not separate anything, so it is only a fallback where the strap reports no activity class.
//
// Pure: no I/O, no clock.

enum AutoWorkoutMotionGate {

    // MARK: Constants

    /// The window's average HR must be at least resting + this (the detector's own floor is resting + 30).
    static let intensityMarginBPM = 45
    /// Share of covered seconds that must be moving: 20% (compared as `moving * 5 >= covered`).
    static let minMovingShareNumerator = 1
    static let minMovingShareDenominator = 5
    /// Less than half of the window's seconds with motion data: not enough to judge, so no suggestion.
    static let minCoverageNumerator = 1
    static let minCoverageDenominator = 2
    /// Gravity fallback: the 10 s trailing mean of the per-record gravity delta above this counts as moving
    /// (the same threshold the workout detector uses).
    static let gravityMovingThreshold = 0.20
    static let gravitySmoothS = 10
    /// Minimum suggestion length the user can choose, in minutes.
    static let durationChoices = [15, 20, 30]
    static let defaultMinMinutes = 15
    static let minMinutesKey = "noopAutoDetectMinMinutes"
    static let requireMotionKey = "noopAutoDetectRequireMotion"

    // MARK: Types

    enum Verdict: String, Equatable {
        case confirmed
        case tooShort
        case lowIntensity
        case noMotion
        case motionMissing

        /// Fixed token for the trace line.
        var why: String {
            switch self {
            case .confirmed: return "ok"
            case .tooShort: return "belowMinDuration"
            case .lowIntensity: return "belowIntensityMargin"
            case .noMotion: return "belowMovingShare"
            case .motionMissing: return "belowCoverage"
            }
        }
    }

    struct Settings: Equatable {
        var minMinutes: Int
        var requireMotion: Bool

        static let standard = Settings(minMinutes: defaultMinMinutes, requireMotion: true)

        /// Reads the stored choices; an unknown duration falls back to the default, the movement switch to ON.
        static func load(defaults: UserDefaults = .standard) -> Settings {
            let stored = defaults.object(forKey: minMinutesKey) as? Int
            let minutes = stored.flatMap { durationChoices.contains($0) ? $0 : nil } ?? defaultMinMinutes
            let require = defaults.object(forKey: requireMotionKey) as? Bool ?? true
            return Settings(minMinutes: minutes, requireMotion: require)
        }
    }

    /// Seconds of the window with motion data, and how many of them were moving.
    struct Tally: Equatable {
        var seconds: Int
        var covered: Int
        var moving: Int
    }

    struct Evaluation: Equatable {
        let verdict: Verdict
        let durationMin: Int
        /// Moving share of the covered seconds, 0...1 (0 when nothing is covered).
        let movingShare: Double
        /// Covered share of the window's seconds, 0...1.
        let coverage: Double
        /// Average HR minus resting HR.
        let hrMargin: Int
    }

    // MARK: Motion

    /// Per second of `[start, end]`: moving when the strap's activity class is 1 or 2, still when it is 0 or
    /// another value. Where a second has NO activity class (WHOOP 4.0, rows banked before the column existed) the
    /// smoothed gravity delta above `gravityMovingThreshold` is used instead. The two are never OR-ed: on real data
    /// that makes the filter pass almost everything. A second with neither is not covered.
    /// `steps` should list the active strap first; the first sample of a timestamp wins.
    static func tally(steps: [StepSample], gravity: [GravitySample], start: Int, end: Int) -> Tally {
        guard end >= start else { return Tally(seconds: 0, covered: 0, moving: 0) }
        var classByTs: [Int: Int] = [:]
        for s in steps where s.ts >= start && s.ts <= end {
            if let c = s.activityClass, classByTs[s.ts] == nil { classByTs[s.ts] = c }
        }
        let smooth = smoothedGravity(gravity)
        var covered = 0, moving = 0
        for t in start...end {
            if let c = classByTs[t] {
                covered += 1
                if c == 1 || c == 2 { moving += 1 }
            } else if let g = smooth[t] {
                covered += 1
                if g > gravityMovingThreshold { moving += 1 }
            }
        }
        return Tally(seconds: end - start + 1, covered: covered, moving: moving)
    }

    /// Trailing mean of the per-record gravity delta over `gravitySmoothS` seconds, keyed by timestamp.
    static func smoothedGravity(_ gravity: [GravitySample]) -> [Int: Double] {
        let points = AutoWorkoutDetector.motionPoints(gravity)
        var out: [Int: Double] = [:]
        out.reserveCapacity(points.count)
        var lo = 0
        var running = 0.0
        for i in points.indices {
            running += points[i].intensity
            while points[i].ts - points[lo].ts > gravitySmoothS { running -= points[lo].intensity; lo += 1 }
            out[points[i].ts] = running / Double(i - lo + 1)
        }
        return out
    }

    // MARK: Verdict

    /// Order: duration, intensity, then (when movement is required) coverage and moving share. With movement off
    /// only duration and intensity decide. `restingBpm` nil falls back to the detector's default (60).
    static func evaluate(_ w: DetectedWorkout, restingBpm: Int?, tally: Tally, settings: Settings) -> Evaluation {
        let resting = restingBpm ?? AutoWorkoutDetector.defaultRestingHR
        let margin = w.avgBpm - resting
        let coverage = tally.seconds > 0 ? Double(tally.covered) / Double(tally.seconds) : 0
        let share = tally.covered > 0 ? Double(tally.moving) / Double(tally.covered) : 0

        let verdict: Verdict
        if w.durationMin < settings.minMinutes {
            verdict = .tooShort
        } else if margin < intensityMarginBPM {
            verdict = .lowIntensity
        } else if settings.requireMotion {
            if tally.covered * minCoverageDenominator < tally.seconds * minCoverageNumerator {
                verdict = .motionMissing
            } else if tally.moving * minMovingShareDenominator < tally.covered * minMovingShareNumerator {
                verdict = .noMotion
            } else {
                verdict = .confirmed
            }
        } else {
            verdict = .confirmed
        }
        return Evaluation(verdict: verdict, durationMin: w.durationMin, movingShare: share,
                          coverage: coverage, hrMargin: margin)
    }

    /// Counts and enum-like reasons only; no timestamps.
    static func traceLine(_ e: Evaluation) -> String {
        "autoDetect gate verdict=\(e.verdict.rawValue) why=\(e.verdict.why) dur=\(e.durationMin)min "
            + "moving=\(Int((e.movingShare * 100).rounded()))% coverage=\(Int((e.coverage * 100).rounded()))% "
            + "hrMargin=\(e.hrMargin)"
    }
}
