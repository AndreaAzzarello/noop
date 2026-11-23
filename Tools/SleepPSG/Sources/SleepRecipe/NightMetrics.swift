import Foundation

// NightMetrics — what a 30 s hypnogram looks like as a night, with no reference label anywhere.
//
// These are INTERNAL-CONSISTENCY measures. They say whether a hypnogram has the shape sleep has (stage shares,
// deep early, REM late, a REM period roughly every 90 minutes, bouts that last more than a few epochs), and how
// jumpy it is. They cannot say whether any individual epoch is right: a hypnogram can sit inside every band and
// still be wrong, and the shipped recipe already carries priors for "deep early, REM late", so passing those
// two is partly the prior speaking. The honest use is to catch a candidate that breaks the shape, never to
// claim one is more accurate.

public struct NightMetrics: Equatable {
    /// False when no run of `onsetSustainedEpochs` non-wake epochs exists; every other field is then zero / nil.
    public let hasSleep: Bool
    public let epochs: Int
    /// Total sleep time, wake after sleep onset, and onset latency from the start of the window, in minutes.
    public let tstMin: Double
    public let wasoMin: Double
    public let latencyMin: Double
    /// Stage shares of total sleep time, in percent.
    public let lightPct: Double
    public let deepPct: Double
    public let remPct: Double
    /// Wake as a share of the sleep period (onset to last non-wake epoch), in percent.
    public let wasoPctOfPeriod: Double
    /// Share of all deep (REM) epochs that fall in the first (second) half of the sleep period, 0...1.
    public let deepFirstHalf: Double?
    public let remSecondHalf: Double?
    /// Minutes from onset to the first REM run of at least two epochs.
    public let firstRemLatencyMin: Double?
    /// Label changes per hour of sleep period, share of bouts shorter than three minutes, median bout length.
    public let transitionsPerHour: Double
    public let shortBoutShare: Double
    public let medianBoutMin: Double
    /// Wake bouts of at least two minutes inside the sleep period.
    public let awakenings: Int
    /// REM periods (runs of at least three minutes, merged across gaps of up to five), and the median spacing
    /// between the onsets of consecutive ones; nil with fewer than two.
    public let remPeriods: Int
    public let remPeriodMin: Double?

    /// Sustained non-wake run that defines onset: the same 5 minutes the stager itself uses.
    public static let onsetSustainedEpochs = 10
    static let shortBoutEpochs = 6        // 3 minutes
    static let awakeningEpochs = 4        // 2 minutes
    static let remMinRunEpochs = 6        // 3 minutes
    static let remMergeGapEpochs = 10     // 5 minutes

    /// Metrics by name, the vocabulary `PlausibilityBands` is written in.
    public var values: [String: Double?] {
        ["lightPct": lightPct, "deepPct": deepPct, "remPct": remPct, "wasoPctOfPeriod": wasoPctOfPeriod,
         "deepFirstHalf": deepFirstHalf, "remSecondHalf": remSecondHalf,
         "firstRemLatencyMin": firstRemLatencyMin, "transitionsPerHour": transitionsPerHour,
         "shortBoutShare": shortBoutShare, "remPeriodMin": remPeriodMin]
    }

    /// `labels` are per-epoch "wake" / "light" / "deep" / "rem" on a grid of `epochSeconds`.
    public static func of(_ labels: [String], epochSeconds: Double = 30) -> NightMetrics {
        let minutes = epochSeconds / 60.0
        func empty() -> NightMetrics {
            NightMetrics(hasSleep: false, epochs: labels.count, tstMin: 0, wasoMin: 0, latencyMin: 0,
                         lightPct: 0, deepPct: 0, remPct: 0, wasoPctOfPeriod: 0, deepFirstHalf: nil,
                         remSecondHalf: nil, firstRemLatencyMin: nil, transitionsPerHour: 0,
                         shortBoutShare: 0, medianBoutMin: 0, awakenings: 0, remPeriods: 0, remPeriodMin: nil)
        }
        var run = 0
        var onset: Int?
        for (i, l) in labels.enumerated() {
            run = l == "wake" ? 0 : run + 1
            if run >= onsetSustainedEpochs { onset = i - onsetSustainedEpochs + 1; break }
        }
        guard let start = onset, let final = labels.lastIndex(where: { $0 != "wake" }), final >= start else {
            return empty()
        }
        let period = Array(labels[start...final])
        let n = period.count
        let count = { (stage: String) in period.filter { $0 == stage }.count }
        let tst = n - count("wake")
        let mid = n / 2

        func share(_ stage: String, inFirstHalf: Bool) -> Double? {
            let total = count(stage)
            guard total > 0 else { return nil }
            let inHalf = period.enumerated().filter { $0.element == stage && (($0.offset < mid) == inFirstHalf) }.count
            return Double(inHalf) / Double(total)
        }

        // Maximal runs of one label inside the sleep period.
        var bouts: [(label: String, start: Int, length: Int)] = []
        for (i, l) in period.enumerated() {
            if let last = bouts.last, last.label == l { bouts[bouts.count - 1].length += 1 }
            else { bouts.append((l, i, 1)) }
        }
        let lengths = bouts.map { $0.length }.sorted()
        let medianLen = lengths.isEmpty ? 0
            : (lengths.count % 2 == 1 ? Double(lengths[lengths.count / 2])
                                      : 0.5 * Double(lengths[lengths.count / 2 - 1] + lengths[lengths.count / 2]))

        var firstRem: Double?
        for b in bouts where b.label == "rem" && b.length >= 2 { firstRem = Double(b.start) * minutes; break }

        // REM periods: long enough runs, merged across short interruptions.
        var periods: [(start: Int, end: Int)] = []
        for b in bouts where b.label == "rem" && b.length >= remMinRunEpochs {
            if let last = periods.last, b.start - last.end <= remMergeGapEpochs {
                periods[periods.count - 1].end = b.start + b.length
            } else {
                periods.append((b.start, b.start + b.length))
            }
        }
        var spacing: Double?
        if periods.count >= 2 {
            let gaps = zip(periods.dropFirst(), periods).map { Double($0.start - $1.start) * minutes }.sorted()
            spacing = gaps.count % 2 == 1 ? gaps[gaps.count / 2] : 0.5 * (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2])
        }

        let hours = Double(n) * minutes / 60.0
        return NightMetrics(
            hasSleep: true, epochs: labels.count,
            tstMin: Double(tst) * minutes, wasoMin: Double(count("wake")) * minutes,
            latencyMin: Double(start) * minutes,
            lightPct: tst > 0 ? 100.0 * Double(count("light")) / Double(tst) : 0,
            deepPct: tst > 0 ? 100.0 * Double(count("deep")) / Double(tst) : 0,
            remPct: tst > 0 ? 100.0 * Double(count("rem")) / Double(tst) : 0,
            wasoPctOfPeriod: 100.0 * Double(count("wake")) / Double(n),
            deepFirstHalf: share("deep", inFirstHalf: true), remSecondHalf: share("rem", inFirstHalf: false),
            firstRemLatencyMin: firstRem,
            transitionsPerHour: hours > 0 ? Double(max(0, bouts.count - 1)) / hours : 0,
            shortBoutShare: bouts.isEmpty ? 0 : Double(bouts.filter { $0.length < shortBoutEpochs }.count) / Double(bouts.count),
            medianBoutMin: medianLen * minutes,
            awakenings: bouts.filter { $0.label == "wake" && $0.length >= awakeningEpochs }.count,
            remPeriods: periods.count, remPeriodMin: spacing)
    }
}

/// Ranges a night's metrics are expected to fall in. There are two sources and they are not equal.
///
/// `broad` is written by hand and is DELIBERATELY WIDE: it exists to flag a hypnogram that is grossly out of
/// shape, not to describe any cohort, and the numbers are the author's, not a published norm. A PSG-derived
/// file (p10..p90 of the scored subjects, written by `sleeppsg --bands-out`) replaces it when one exists;
/// anything that depends on a tight bound — fragmentation above all — should wait for that file.
public struct PlausibilityBands: Equatable {
    public let source: String
    public let ranges: [String: ClosedRange<Double>]

    public static let broad = PlausibilityBands(source: "broad plausibility bounds (author's, deliberately wide; not a cohort)", ranges: [
        "lightPct": 35...75, "deepPct": 3...30, "remPct": 10...35, "wasoPctOfPeriod": 0...25,
        "deepFirstHalf": 0.5...1.0, "remSecondHalf": 0.5...1.0, "firstRemLatencyMin": 30...180,
        "remPeriodMin": 60...130, "transitionsPerHour": 4...40, "shortBoutShare": 0...0.6])

    /// `{"source": "...", "ranges": {"deepPct": [lo, hi], ...}}`
    public static func parse(json: Data) throws -> PlausibilityBands {
        struct File: Decodable { let source: String; let ranges: [String: [Double]] }
        let file = try JSONDecoder().decode(File.self, from: json)
        var out: [String: ClosedRange<Double>] = [:]
        for (key, pair) in file.ranges where pair.count == 2 && pair[0] <= pair[1] { out[key] = pair[0]...pair[1] }
        return PlausibilityBands(source: file.source, ranges: out)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct File: Encodable { let source: String; let ranges: [String: [Double]] }
        return try enc.encode(File(source: source, ranges: ranges.mapValues { [$0.lowerBound, $0.upperBound] }))
    }

    /// nil when the band has no range for `metric` or the night has no value for it.
    public func contains(_ metric: String, _ value: Double?) -> Bool? {
        guard let range = ranges[metric], let value, value.isFinite else { return nil }
        return range.contains(value)
    }

    /// (inside, judged) over every metric both sides know.
    public func score(_ metrics: NightMetrics) -> (inside: Int, judged: Int) {
        var inside = 0, judged = 0
        for (name, value) in metrics.values {
            if let ok = contains(name, value) { judged += 1; if ok { inside += 1 } }
        }
        return (inside, judged)
    }
}
