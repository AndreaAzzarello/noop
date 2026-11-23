// Replays recorded nights through the real Smart Wake controller (engine + light-sleep rule), exactly as the app
// feeds it: heart rate at ~1 Hz with the RR of the same second, a 60 minute pre-window baseline, the same window.
//
//   swiftc -O StrandiOSShared/SmartWakeEngine.swift StrandiOSShared/SmartWakeLiveController.swift \
//       Tools/SmartWakeReplay/main.swift -o /tmp/swr
//   /tmp/swr /tmp/smartwake-nights [--window 30] [--offsets 0,-60,-120] [--stages-dir DIR] [-v]
//
// `--stages-dir DIR` replaces the stored stages of every night that has a `night_<startTs>.csv` in DIR (only its
// `S,` lines are read) with that file's. `sleepbench --stages-out` writes one such folder per recipe, so the same
// replay can be read against the incumbent and each candidate. It also prints, over every replayed window, how
// often the live filter's most likely stage matches the offline hypnogram epoch for epoch. That agreement is
// CIRCULAR evidence: the live detector copies the offline recipe's constants, so it measures coherence between
// the two, not whether either is right.
//
// For each night and each offset it simulates a maximum wake time of `session end + offset minutes`, runs the
// window, and reports which rule woke the user, how early, and what the after-the-night V2 stages and the strap's
// own sleep_state said at that moment. The aggregate is what decides whether the thresholds are usable: if most
// wakes land in the first minutes of the window, or in V2 "deep", the rule is not tracking sleep depth.
import Foundation

struct Night {
    var start = 0
    var end = 0
    var stages: [(start: Int, end: Int, stage: String)] = []
    var hr: [(ts: Int, bpm: Int)] = []
    var rr: [Int: [Int]] = [:]
    var band: [(ts: Int, state: Int)] = []

    func stage(at ts: Int) -> String {
        stages.first { $0.start <= ts && ts < $0.end }?.stage ?? "none"
    }

    func bandState(at ts: Int) -> Int? {
        var best: (distance: Int, state: Int)?
        for sample in band where abs(sample.ts - ts) <= 90 {
            let distance = abs(sample.ts - ts)
            if best == nil || distance < best!.distance { best = (distance, sample.state) }
        }
        return best?.state
    }
}

struct Outcome {
    let night: Int
    let offsetMinutes: Int
    let reason: String            // "lightSleep", "rise", or "none"
    let minutesEarly: Double      // 0 when nothing fired
    let minutesIntoWindow: Double
    let v2Stage: String
    let bandState: Int?
    let summary: String
}

/// The `S,` lines of a stages file, nothing else.
func loadStages(_ url: URL) -> [(start: Int, end: Int, stage: String)]? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var out: [(start: Int, end: Int, stage: String)] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: ",")
        if parts.first == "S", parts.count >= 4, let s = Int(parts[1]), let e = Int(parts[2]) {
            out.append((s, e, String(parts[3])))
        }
    }
    return out.isEmpty ? nil : out
}

func load(_ url: URL) -> Night? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var night = Night()
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: ",")
        guard let kind = parts.first else { continue }
        switch kind {
        case "N" where parts.count >= 3:
            night.start = Int(parts[1]) ?? 0
            night.end = Int(parts[2]) ?? 0
        case "S" where parts.count >= 4:
            if let start = Int(parts[1]), let end = Int(parts[2]) {
                night.stages.append((start, end, String(parts[3])))
            }
        case "H" where parts.count >= 3:
            if let ts = Int(parts[1]), let bpm = Int(parts[2]) { night.hr.append((ts, bpm)) }
        case "R" where parts.count >= 3:
            if let ts = Int(parts[1]), let value = Int(parts[2]) { night.rr[ts, default: []].append(value) }
        case "B" where parts.count >= 3:
            if let ts = Int(parts[1]), let state = Int(parts[2]) { night.band.append((ts, state)) }
        default:
            break
        }
    }
    return night.end > night.start && !night.hr.isEmpty ? night : nil
}

/// Per-epoch agreement over one window between the live filter's most likely stage (the `epochs=` trace the
/// detector keeps for its summary: D deep, R REM, L light, A awake, `.` unusable) and the offline stages.
///
/// The detector is driven to the END of the window, past the sample that would have woken the user, because
/// the question is how well its filter tracks the offline hypnogram, not when the rule fires. A window whose
/// trace is missing more than two epochs had holes in the stream, and its positions no longer line up with the
/// clock, so it is left out rather than compared misaligned.
func traceAgreement(_ night: Night, offsetMinutes: Int, windowMinutes: Int) -> (live: [String], offline: [String])? {
    let maximumWake = night.end + offsetMinutes * 60
    let windowSeconds = windowMinutes * 60
    let windowStart = maximumWake - windowSeconds
    let samples = night.hr.filter { $0.ts >= windowStart - 3_600 && $0.ts < maximumWake }
    guard samples.filter({ $0.ts < windowStart }).count >= 1_800,
          samples.filter({ $0.ts >= windowStart }).count >= windowSeconds / 2
    else { return nil }
    var detector = SmartWakeLightSleepDetector(maximumWakeTime: Date(timeIntervalSince1970: TimeInterval(maximumWake)),
                                               windowDuration: TimeInterval(windowSeconds))
    for sample in samples {
        detector.ingest(bpm: sample.bpm, at: Date(timeIntervalSince1970: TimeInterval(sample.ts)), rr: night.rr[sample.ts] ?? [])
    }
    guard let range = detector.summary.range(of: "epochs=") else { return nil }
    let trace = detector.summary[range.upperBound...].prefix { !$0.isWhitespace }
    guard trace.count >= windowSeconds / 30 - 2 else { return nil }
    let firstEpoch = (windowStart + 29) / 30 * 30
    let names: [Character: String] = ["D": "deep", "R": "rem", "L": "light", "A": "wake"]
    var live: [String] = [], offline: [String] = []
    for (i, letter) in trace.enumerated() {
        guard let stage = names[letter] else { continue }
        let reference = night.stage(at: firstEpoch + 30 * i + 15)
        guard reference != "none" else { continue }
        live.append(stage)
        offline.append(reference == "awake" ? "wake" : reference)
    }
    return (live, offline)
}

func replay(_ night: Night, offsetMinutes: Int, windowMinutes: Int) -> Outcome? {
    let maximumWake = night.end + offsetMinutes * 60
    let windowSeconds = windowMinutes * 60
    let windowStart = maximumWake - windowSeconds
    let samples = night.hr.filter { $0.ts >= windowStart - 3_600 && $0.ts < maximumWake }
    // Needs a real baseline and a mostly populated window, or the night says nothing about the rule.
    guard samples.filter({ $0.ts < windowStart }).count >= 1_800,
          samples.filter({ $0.ts >= windowStart }).count >= windowSeconds / 2
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let schedule = SmartWakeSchedule(
        wakeMinutes: (maximumWake % 86_400) / 60,
        weekdays: [],
        overrides: [:],
        windowDuration: TimeInterval(windowSeconds)
    )
    let defaults = UserDefaults(suiteName: "SmartWakeReplay.\(UUID().uuidString)")!
    let controller = SmartWakeLiveController(schedule: schedule, calendar: calendar, defaults: defaults)
    var summary = ""
    controller.onWindowSummary = { summary = $0 }

    var fired: (ts: Int, reason: String)?
    for sample in samples {
        let decision = controller.ingest(
            bpm: sample.bpm,
            at: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
            rr: night.rr[sample.ts] ?? []
        )
        if case let .wake(reason) = decision {
            fired = (sample.ts, reason == .lightSleep ? "lightSleep" : (reason == .sustainedHeartRateRise ? "rise" : "none"))
            break
        }
    }
    if fired == nil { controller.finalizeWindowStats() }

    if let fired, fired.reason != "none" {
        return Outcome(
            night: night.start, offsetMinutes: offsetMinutes, reason: fired.reason,
            minutesEarly: Double(maximumWake - fired.ts) / 60,
            minutesIntoWindow: Double(fired.ts - windowStart) / 60,
            v2Stage: night.stage(at: fired.ts), bandState: night.bandState(at: fired.ts), summary: summary)
    }
    return Outcome(
        night: night.start, offsetMinutes: offsetMinutes, reason: "none", minutesEarly: 0, minutesIntoWindow: 0,
        v2Stage: "-", bandState: nil, summary: summary)
}

/// Share of the window's seconds that V2 labels with each stage: the "if the wake time were random" reference.
func stageShares(_ night: Night, offsetMinutes: Int, windowMinutes: Int) -> [String: Double] {
    let end = night.end + offsetMinutes * 60
    let start = end - windowMinutes * 60
    var counts: [String: Int] = [:]
    var total = 0
    var ts = start
    while ts < end {
        counts[night.stage(at: ts), default: 0] += 1
        total += 1
        ts += 30
    }
    guard total > 0 else { return [:] }
    return counts.mapValues { Double($0) / Double(total) }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

// MARK: - Main

var directory: String?
var windowMinutes = 30
var offsets = [0, -60, -120]
var verbose = false
var stagesDirectory: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--window": windowMinutes = Int(arguments.isEmpty ? "30" : arguments.removeFirst()) ?? 30
    case "--offsets": offsets = (arguments.isEmpty ? "0" : arguments.removeFirst()).split(separator: ",").compactMap { Int($0) }
    case "--stages-dir": stagesDirectory = arguments.isEmpty ? nil : arguments.removeFirst()
    case "-v": verbose = true
    default: directory = argument
    }
}
guard let inputDirectory = directory else {
    print("usage: swr <dir of night_*.csv> [--window 30] [--offsets 0,-60,-120] [--stages-dir DIR] [-v]")
    exit(2)
}

let files = ((try? FileManager.default.contentsOfDirectory(atPath: inputDirectory)) ?? [])
    .filter { $0.hasPrefix("night_") && $0.hasSuffix(".csv") }
    .sorted()
var outcomes: [Outcome] = []
var referenceShares: [String: Double] = [:]
var referenceWindows = 0
var agreementLive: [String] = [], agreementOffline: [String] = []
var agreementWindows = 0, nightsRestaged = 0
for file in files {
    guard var night = load(URL(fileURLWithPath: inputDirectory).appendingPathComponent(file)) else { continue }
    if let stagesDirectory,
       let replacement = loadStages(URL(fileURLWithPath: stagesDirectory).appendingPathComponent(file)) {
        night.stages = replacement
        nightsRestaged += 1
    }
    for offset in offsets {
        guard let outcome = replay(night, offsetMinutes: offset, windowMinutes: windowMinutes) else { continue }
        outcomes.append(outcome)
        if let pair = traceAgreement(night, offsetMinutes: offset, windowMinutes: windowMinutes) {
            agreementLive += pair.live; agreementOffline += pair.offline; agreementWindows += 1
        }
        for (stage, share) in stageShares(night, offsetMinutes: offset, windowMinutes: windowMinutes) {
            referenceShares[stage, default: 0] += share
        }
        referenceWindows += 1
        if verbose {
            print("night \(outcome.night) end\(outcome.offsetMinutes >= 0 ? "+" : "")\(outcome.offsetMinutes)m: "
                + "\(outcome.reason) early=\(String(format: "%.1f", outcome.minutesEarly))m v2=\(outcome.v2Stage) "
                + "band=\(outcome.bandState.map(String.init) ?? "-")\n    \(outcome.summary)")
        }
    }
}

// MARK: - Live filter against the offline hypnogram

print("\nLIVE FILTER vs OFFLINE STAGES, epoch for epoch (circular: both derive from the same recipe's constants)")
if agreementLive.isEmpty {
    print("  no window had a complete trace to compare")
} else {
    let agree = zip(agreementLive, agreementOffline).filter { $0 == $1 }.count
    print(String(format: "  windows %d, epochs %d, 4-stage agreement %.1f%%", agreementWindows, agreementLive.count,
                 100 * Double(agree) / Double(agreementLive.count)))
    // Light against everything else is the only distinction the wake rule acts on.
    var tp = 0, fp = 0, fn = 0, tn = 0
    for (l, o) in zip(agreementLive, agreementOffline) {
        switch (l == "light", o == "light") {
        case (true, true): tp += 1
        case (true, false): fp += 1
        case (false, true): fn += 1
        case (false, false): tn += 1
        }
    }
    let n = Double(tp + fp + fn + tn)
    let po = Double(tp + tn) / n
    let pe = (Double(tp + fp) * Double(tp + fn) + Double(fn + tn) * Double(fp + tn)) / (n * n)
    print(String(format: "  light vs not-light: agreement %.1f%%, kappa %.3f (live light %d, offline light %d of %d)",
                 100 * po, pe >= 1 ? Double.nan : (po - pe) / (1 - pe), tp + fp, tp + fn, Int(n)))
    for stage in ["deep", "rem", "light", "wake"] {
        let live = agreementLive.filter { $0 == stage }.count, offline = agreementOffline.filter { $0 == stage }.count
        print(String(format: "    %-5@ live %5d (%4.1f%%)   offline %5d (%4.1f%%)", stage as NSString,
                     live, 100 * Double(live) / Double(agreementLive.count),
                     offline, 100 * Double(offline) / Double(agreementOffline.count)))
    }
}

if let stagesDirectory {
    print("stages from \(stagesDirectory) for \(nightsRestaged) night(s); the rest keep the stages in their night file")
}
print("windows replayed: \(outcomes.count) (window \(windowMinutes) min, offsets \(offsets) min from session end)")
guard !outcomes.isEmpty else { print("nothing to report: no night had a baseline and a populated window"); exit(1) }

let fired = outcomes.filter { $0.reason != "none" }
print("woke early: \(fired.count) / \(outcomes.count)  "
    + "(lightSleep \(fired.filter { $0.reason == "lightSleep" }.count), rise \(fired.filter { $0.reason == "rise" }.count))")
guard !fired.isEmpty else { print("the rule never woke early on these nights"); exit(0) }

let early = fired.map(\.minutesEarly)
print(String(format: "minutes early: p10 %.1f  median %.1f  p90 %.1f", percentile(early, 0.1), percentile(early, 0.5), percentile(early, 0.9)))
let intoWindow = fired.map(\.minutesIntoWindow)
let firstMinutes = intoWindow.filter { $0 < 3 }.count
print(String(format: "woke within the first 3 minutes of the window: %d / %d (%.0f%%)  <- if this is most of them the rule is not tracking sleep",
             firstMinutes, fired.count, 100 * Double(firstMinutes) / Double(fired.count)))

print("\nwake time inside the window, 5 minute bins (minutes into the window):")
for bin in stride(from: 0, to: windowMinutes, by: 5) {
    let count = intoWindow.filter { $0 >= Double(bin) && $0 < Double(bin + 5) }.count
    print(String(format: "  %2d-%2d min: %@ %d", bin, bin + 5, String(repeating: "#", count: min(count, 60)), count))
}

print("\nV2 stage (computed after the night) at the moment of the wake, against the share of the window each stage had:")
for stage in ["light", "rem", "deep", "wake", "awake", "none"] {
    let atWake = fired.filter { $0.v2Stage == stage }.count
    let reference = referenceShares[stage].map { $0 / Double(referenceWindows) } ?? 0
    if atWake == 0 && reference == 0 { continue }
    let label = stage.padding(toLength: 6, withPad: " ", startingAt: 0)
    print("  " + label + String(format: " at wake %3d (%2.0f%%)   window share %2.0f%%", atWake,
                                100 * Double(atWake) / Double(fired.count), 100 * reference))
}

print("\nstrap sleep_state at the moment of the wake (0 wake, 1 still, 2 asleep, 3 up):")
for state in 0...3 {
    let count = fired.filter { $0.bandState == state }.count
    print("  state \(state): \(count)")
}
print("  no reading: \(fired.filter { $0.bandState == nil }.count)")
