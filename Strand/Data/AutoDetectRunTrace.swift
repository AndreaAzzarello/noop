import Foundation

// MARK: - Workouts & GPS test mode: why `autoDetectCandidate` did (not) offer a workout
//
// Pure string builders for the lines `Repository.autoDetectCandidate` emits on every path, including the
// early exits that used to leave the Test Centre report with "mode was on but produced NO trace". All
// lines start with `autoDetect`, the token `CaptureCompleteness` looks for in the workouts domain.
// No PII: counts and enum-like reasons only.

enum AutoDetectRunTrace {

    /// Number of HR samples the scan needs before it can run (`guard samples.count >= 2`).
    static let minSamples = 2

    static func entry(daysBack: Int, enabled: Bool) -> String {
        "autoDetect run daysBack=\(daysBack) enabled=\(enabled)"
    }

    static func skipToggleOff() -> String {
        "autoDetect skip why=toggleOff"
    }

    static func skipTooFewSamples(count: Int) -> String {
        "autoDetect skip why=tooFewHrSamples hrSamples=\(count) needed=\(minSamples)"
    }

    /// `offered` = windows the detector returned; `picked` = whether one survived the dismissed filter.
    static func selection(offered: Int, picked: Bool) -> String {
        if picked { return "autoDetect select offered=\(offered) picked=yes" }
        let why = offered == 0 ? "noWindows" : "allDismissed"
        return "autoDetect select offered=\(offered) picked=no why=\(why)"
    }
}
