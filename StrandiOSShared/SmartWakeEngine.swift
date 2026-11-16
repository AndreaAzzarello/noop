import Foundation

/// Pure, deterministic heart-rate heuristic for the iOS Smart Wake prototype.
///
/// This is deliberately not a sleep-stage classifier. It looks for a sustained rise
/// (a rolling 120 s window that is mostly above a robust pre-window baseline) and never treats missing/poor data as a reason
/// to wake early. The separately scheduled maximum-time alarm remains the fallback.
struct SmartWakeHeartRateSample: Equatable, Codable {
    let bpm: Int
    let timestamp: Date
}

struct SmartWakeConfiguration {
    let maximumWakeTime: Date
    let windowDuration: TimeInterval
    let riseThresholdBPM: Double
    let minimumBaselineSamples: Int
    /// Minimum samples inside the rolling rise window before a decision can be made.
    let requiredElevatedSamples: Int
    let minimumRiseDuration: TimeInterval
    /// Share of the rolling window's samples that must be elevated. Tolerates isolated noisy
    /// samples at ~1 Hz while still rejecting a prolonged dip.
    let minimumElevatedFraction: Double
    let maximumSampleGap: TimeInterval
    let maximumSampleAge: TimeInterval

    var windowStart: Date {
        maximumWakeTime.addingTimeInterval(-windowDuration)
    }

    static func standard(
        maximumWakeTime: Date,
        windowDuration: TimeInterval = 30 * 60
    ) -> SmartWakeConfiguration {
        SmartWakeConfiguration(
            maximumWakeTime: maximumWakeTime,
            windowDuration: max(0, windowDuration),
            riseThresholdBPM: 6,
            minimumBaselineSamples: 20,
            requiredElevatedSamples: 3,
            minimumRiseDuration: 120,
            minimumElevatedFraction: 0.8,
            maximumSampleGap: 180,
            maximumSampleAge: 300
        )
    }
}

enum SmartWakeTrigger: Equatable {
    case sustainedHeartRateRise
    /// The causal light-sleep rule (`SmartWakeLightSleepDetector`) estimated light sleep for several epochs in a row.
    case lightSleep
    case maximumWakeTime
}

enum SmartWakeDecision: Equatable {
    case waiting
    case wake(SmartWakeTrigger)
    case alreadyTriggered
}

struct SmartWakeEngine {
    private let configuration: SmartWakeConfiguration
    private let baselineMedianBPM: Double?
    private var recentSamples: [(timestamp: Date, isElevated: Bool)] = []
    private var seriesStart: Date?
    private var lastSampleTimestamp: Date?
    private var trigger: SmartWakeTrigger?

    init(configuration: SmartWakeConfiguration, baselineSamples: [SmartWakeHeartRateSample]) {
        self.configuration = configuration

        let validBaseline = baselineSamples
            .filter {
                $0.timestamp < configuration.windowStart &&
                (30...220).contains($0.bpm)
            }
            .map(\.bpm)
            .sorted()

        if validBaseline.count >= configuration.minimumBaselineSamples {
            let middle = validBaseline.count / 2
            if validBaseline.count.isMultiple(of: 2) {
                baselineMedianBPM = Double(validBaseline[middle - 1] + validBaseline[middle]) / 2
            } else {
                baselineMedianBPM = Double(validBaseline[middle])
            }
        } else {
            baselineMedianBPM = nil
        }
    }

    /// Feed one newly received strap sample. Call only for newly delivered samples;
    /// the engine still rejects invalid, duplicate, out-of-order and stale values.
    mutating func ingest(_ sample: SmartWakeHeartRateSample, at now: Date) -> SmartWakeDecision {
        if trigger != nil { return .alreadyTriggered }
        if now >= configuration.maximumWakeTime {
            return fire(.maximumWakeTime)
        }

        guard now >= configuration.windowStart,
              now < configuration.maximumWakeTime,
              sample.timestamp >= configuration.windowStart,
              sample.timestamp <= now,
              now.timeIntervalSince(sample.timestamp) <= configuration.maximumSampleAge,
              (30...220).contains(sample.bpm),
              let baselineMedianBPM
        else {
            return .waiting
        }

        // Enforce monotonic timestamps for every valid sample, not only elevated ones.
        if let lastSampleTimestamp, sample.timestamp <= lastSampleTimestamp {
            return .waiting
        }
        lastSampleTimestamp = sample.timestamp

        // A hole in the data restarts the series: missing samples are never evidence of a rise.
        if let previous = recentSamples.last,
           sample.timestamp.timeIntervalSince(previous.timestamp) > configuration.maximumSampleGap {
            recentSamples.removeAll(keepingCapacity: true)
            seriesStart = nil
        }
        if seriesStart == nil { seriesStart = sample.timestamp }

        let isElevated = Double(sample.bpm) >= baselineMedianBPM + configuration.riseThresholdBPM
        recentSamples.append((timestamp: sample.timestamp, isElevated: isElevated))
        let cutoff = sample.timestamp.addingTimeInterval(-configuration.minimumRiseDuration)
        recentSamples.removeAll { $0.timestamp < cutoff }

        // Rolling window of the last `minimumRiseDuration` seconds: the series must have been
        // observed continuously for that long, and most of the window must be elevated. A short
        // dip is tolerated; a sustained one pulls the share under the threshold.
        guard let seriesStart,
              sample.timestamp.timeIntervalSince(seriesStart) >= configuration.minimumRiseDuration,
              recentSamples.count >= configuration.requiredElevatedSamples
        else {
            return .waiting
        }
        let elevatedCount = recentSamples.filter(\.isElevated).count
        guard Double(elevatedCount) / Double(recentSamples.count) >= configuration.minimumElevatedFraction else {
            return .waiting
        }

        return fire(.sustainedHeartRateRise)
    }

    /// Evaluate the independent hard deadline even if no heart-rate samples arrived.
    mutating func evaluate(at now: Date) -> SmartWakeDecision {
        if trigger != nil { return .alreadyTriggered }
        guard now >= configuration.maximumWakeTime else { return .waiting }
        return fire(.maximumWakeTime)
    }

    /// Records that another rule (the light-sleep detector) has decided to wake, so this engine reports
    /// `.alreadyTriggered` from then on instead of firing a second, different reason.
    mutating func markTriggered(_ reason: SmartWakeTrigger) -> SmartWakeDecision {
        if trigger != nil { return .alreadyTriggered }
        return fire(reason)
    }

    private mutating func fire(_ reason: SmartWakeTrigger) -> SmartWakeDecision {
        trigger = reason
        return .wake(reason)
    }
}

// MARK: - Light-sleep rule

/// Causal, live variant of the V2 sleep stager (`SleepStagerV2`, Packages/StrandAnalytics) for the Smart Wake window.
///
/// V2 cannot run as written while the night is still in progress: its z-scores, percentiles and sleep-cycle clock
/// use the whole night, its features look up to 390 s ahead and it decodes with a two-pass Viterbi. Overnight on a
/// WHOOP 5.0 only heart rate (~1 Hz) and RR arrive live; gravity arrives only with the history download. So this
/// keeps V2's HR/RR recipe and drops everything that needs the future or the wrist:
///   - features use only PAST samples (5 and 11 minute trailing windows instead of centred ones);
///   - z-scores and the flatness percentile are taken against the epochs seen so far, not the whole night;
///   - the sleep-cycle clock is estimated from the time left to the maximum wake time;
///   - motion is absent, so V2's "still wrist" case applies to every epoch: HR alone never votes "awake"
///     (the live rule therefore separates deep / REM / light, not wake);
///   - decoding is a forward filter (an HMM with V2's transition matrix) instead of Viterbi.
///
/// The constants are V2's (`SleepStagerV2.swift` `baseLogPrior`, `transition`, the emission scores in `stageEpochs`).
/// The wake threshold and the number of epochs are NOT validated yet: confirm them with `Tools/SmartWakeReplay`
/// on recorded nights before relying on them. RR for the reference epochs is not retained across a relaunch (the
/// persisted baseline holds heart rate only), so the respiration term is used only once enough epochs carry it.
struct SmartWakeLightSleepDetector {
    /// Order of the entries in every probability / score array below.
    enum Stage: Int, CaseIterable {
        case deep, rem, light, awake

        var label: String {
            switch self {
            case .deep: return "deep"
            case .rem: return "rem"
            case .light: return "light"
            case .awake: return "awake"
            }
        }
    }

    struct Configuration: Equatable {
        var epochSeconds: TimeInterval = 30
        /// Epochs before the window that must carry a heart-rate variability feature. Fewer: no early wake.
        var minimumReferenceEpochs = 60
        /// An epoch needs this many samples (of ~30 at 1 Hz) and no hole longer than `maximumGapSeconds`.
        var minimumSamplesPerEpoch = 20
        var maximumGapSeconds: TimeInterval = 10
        /// Provisional: P(light) required, for `requiredConsecutiveEpochs` epochs in a row.
        var lightProbabilityThreshold = 0.60
        var requiredConsecutiveEpochs = 3
        /// Trailing windows of the two HR spread features (V2: 5 and 11 minutes, centred).
        var variabilityEpochs = 10
        var variabilityMinimumEpochs = 5
        var flatnessEpochs = 22
        var flatnessMinimumEpochs = 11
        var respirationWindowSeconds: TimeInterval = 210
        var respirationMinimumReference = 20
        /// Used only to place an epoch in the night for the sleep-cycle prior.
        var assumedNightSeconds: TimeInterval = 7.5 * 3600
        var historyEpochs = 400

        static let standard = Configuration()
    }

    struct Diagnostics: Equatable {
        var referenceEpochs = 0
        var windowEpochs = 0
        var invalidEpochs = 0
        var maximumLightProbability = 0.0
        var stageCounts = [0, 0, 0, 0]
        var firedAt: Date?
        var firedProbability: Double?
    }

    let configuration: Configuration
    let windowStart: Date
    let maximumWakeTime: Date
    private(set) var diagnostics = Diagnostics()

    private struct Accumulator {
        let index: Int
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        var lastTime: Double?
        var maximumGap = 0.0

        mutating func add(_ bpm: Double, at time: Double) {
            if let lastTime { maximumGap = max(maximumGap, time - lastTime) }
            lastTime = time
            count += 1
            sum += bpm
            sumSquares += bpm * bpm
        }
    }

    private struct ClosedEpoch {
        let index: Int
        /// 0 marks an epoch that was seen but not usable (too few samples or a hole).
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        var heartRate: Double?
        var variability: Double?
        var flatness: Double?
        var respiration: Double?
    }

    private struct Beat {
        let time: Double
        let rrMilliseconds: Double
    }

    private var current: Accumulator?
    private var history: [ClosedEpoch] = []
    private var beats: [Beat] = []
    private var belief: [Double]?
    private var streak = 0
    private var lastClosedIndex: Int?
    private var lastSampleTime: Double?
    private var hasFired = false

    init(maximumWakeTime: Date, windowDuration: TimeInterval, configuration: Configuration = .standard) {
        self.configuration = configuration
        self.maximumWakeTime = maximumWakeTime
        self.windowStart = maximumWakeTime.addingTimeInterval(-max(0, windowDuration))
    }

    /// Feeds the persisted pre-window heart rate (no RR) as reference epochs.
    mutating func seed(_ samples: [SmartWakeHeartRateSample]) {
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            _ = ingest(bpm: sample.bpm, at: sample.timestamp)
        }
    }

    /// Feeds one heart-rate notification and the RR intervals (ms) it carried. Returns true once, on the sample that
    /// closes the epoch that completes the rule.
    @discardableResult
    mutating func ingest(bpm: Int, at timestamp: Date, rr: [Int] = []) -> Bool {
        guard (30...220).contains(bpm) else { return false }
        let time = timestamp.timeIntervalSince1970
        if let lastSampleTime, time <= lastSampleTime { return false }
        lastSampleTime = time
        addBeats(rr, endingAt: time)

        let index = Int((time / configuration.epochSeconds).rounded(.down))
        var fired = false
        if let current, current.index != index {
            fired = closeCurrentEpoch(closedAt: timestamp)
            self.current = nil
        }
        if current == nil { current = Accumulator(index: index) }
        current?.add(Double(bpm), at: time)
        return fired
    }

    /// One line for the Smart Wake diagnostics: why the rule did or did not wake early.
    var summary: String {
        let stages = Stage.allCases.map { "\($0.label)=\(diagnostics.stageCounts[$0.rawValue])" }.joined(separator: " ")
        var text = "reference=\(diagnostics.referenceEpochs) windowEpochs=\(diagnostics.windowEpochs) "
            + "invalid=\(diagnostics.invalidEpochs) maxLight=\(String(format: "%.2f", diagnostics.maximumLightProbability)) \(stages)"
        if let firedAt = diagnostics.firedAt, let probability = diagnostics.firedProbability {
            text += " fired=\(firedAt.formatted(date: .omitted, time: .standard)) P=\(String(format: "%.2f", probability))"
        } else if diagnostics.referenceEpochs < configuration.minimumReferenceEpochs {
            text += " fired=none (reference too short)"
        } else if diagnostics.windowEpochs == 0 {
            text += " fired=none (no valid window epochs)"
        } else if diagnostics.maximumLightProbability < configuration.lightProbabilityThreshold {
            text += " fired=none (never light)"
        } else {
            text += " fired=none (not sustained)"
        }
        return text
    }

    // MARK: Epoch closing

    private mutating func closeCurrentEpoch(closedAt now: Date) -> Bool {
        guard let epoch = current else { return false }
        let epochStart = Double(epoch.index) * configuration.epochSeconds
        let epochEnd = epochStart + configuration.epochSeconds
        let isInWindow = Date(timeIntervalSince1970: epochStart) >= windowStart && now < maximumWakeTime
        let isContiguous = lastClosedIndex == epoch.index - 1
        lastClosedIndex = epoch.index

        guard epoch.count >= configuration.minimumSamplesPerEpoch,
              epoch.maximumGap <= configuration.maximumGapSeconds
        else {
            history.append(ClosedEpoch(index: epoch.index))
            trimHistory()
            streak = 0
            if isInWindow { diagnostics.invalidEpochs += 1 }
            return false
        }
        if !isContiguous { streak = 0 }

        var closed = ClosedEpoch(index: epoch.index, count: epoch.count, sum: epoch.sum, sumSquares: epoch.sumSquares)
        closed.heartRate = epoch.sum / Double(epoch.count)
        history.append(closed)
        let position = history.count - 1
        history[position].variability = pooledDeviation(
            endingAt: epoch.index, epochs: configuration.variabilityEpochs, minimumValid: configuration.variabilityMinimumEpochs)
        history[position].flatness = pooledDeviation(
            endingAt: epoch.index, epochs: configuration.flatnessEpochs, minimumValid: configuration.flatnessMinimumEpochs)
        history[position].respiration = respirationRegularity(epochEnd: epochEnd)
        trimHistory()

        let windowStartIndex = Int((windowStart.timeIntervalSince1970 / configuration.epochSeconds).rounded(.down))
        diagnostics.referenceEpochs = history.filter { $0.index < windowStartIndex && $0.variability != nil }.count
        guard diagnostics.referenceEpochs >= configuration.minimumReferenceEpochs,
              let latest = history.last
        else {
            streak = 0
            return false
        }

        let probabilities = advanceFilter(with: latest, epochStart: epochStart)
        guard isInWindow else {
            streak = 0
            return false
        }

        let light = probabilities[Stage.light.rawValue]
        diagnostics.windowEpochs += 1
        diagnostics.maximumLightProbability = max(diagnostics.maximumLightProbability, light)
        if let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) {
            diagnostics.stageCounts[best] += 1
        }
        if hasFired { return false }
        streak = light >= configuration.lightProbabilityThreshold ? streak + 1 : 0
        guard streak >= configuration.requiredConsecutiveEpochs else { return false }
        hasFired = true
        diagnostics.firedAt = now
        diagnostics.firedProbability = light
        return true
    }

    private mutating func trimHistory() {
        if history.count > configuration.historyEpochs {
            history.removeFirst(history.count - configuration.historyEpochs)
        }
    }

    /// Standard deviation of the per-sample heart rate over the trailing `epochs` epochs, pooled; nil when fewer
    /// than `minimumValid` of them were usable.
    private func pooledDeviation(endingAt index: Int, epochs: Int, minimumValid: Int) -> Double? {
        var samples = 0.0, sum = 0.0, squares = 0.0
        var valid = 0
        for epoch in history.reversed() {
            if epoch.index <= index - epochs { break }
            guard epoch.count > 0 else { continue }
            valid += 1
            samples += Double(epoch.count)
            sum += epoch.sum
            squares += epoch.sumSquares
        }
        guard valid >= minimumValid, samples > 0 else { return nil }
        let mean = sum / samples
        return max(0, squares / samples - mean * mean).squareRoot()
    }

    // MARK: RR / respiration

    private mutating func addBeats(_ rr: [Int], endingAt end: Double) {
        var time = end
        var fresh: [Beat] = []
        for value in rr.reversed() {
            guard (250...3000).contains(value) else { break }
            fresh.append(Beat(time: time, rrMilliseconds: Double(value)))
            time -= Double(value) / 1000
        }
        let newest = beats.last?.time ?? -Double.infinity
        beats.append(contentsOf: fresh.reversed().filter { $0.time > newest })
        beats.removeAll { $0.time < end - 400 }
    }

    private func respirationRegularity(epochEnd: Double) -> Double? {
        let lower = epochEnd - configuration.respirationWindowSeconds
        let window = beats
            .filter { $0.time >= lower && $0.time < epochEnd }
            .map { ($0.time, $0.rrMilliseconds) }
        return Self.respRegularity(window)
    }

    /// RSA respiration regularity, ported from `SleepStagerV2.respRegularity`: tachogram, 4 Hz resample, detrend,
    /// power in the 0.15-0.40 Hz band, peak / total. Higher means more regular breathing; nil with too few beats.
    static func respRegularity(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats[0].0, tN = beats[beats.count - 1].0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))
        if n < 16 { return nil }

        var y = [Double](repeating: 0, count: n)
        var segment = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while segment < beats.count - 2 && beats[segment + 1].0 < t { segment += 1 }
            let ta = beats[segment].0, tb = beats[segment + 1].0
            let va = beats[segment].1, vb = beats[segment + 1].1
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        let kLow = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHigh = Int(floor(0.40 * 0.25 * Double(n)))
        if kHigh < kLow || kLow < 0 { return nil }
        var peak = 0.0, total = 0.0
        for k in kLow...kHigh {
            let step = 2 * Double.pi * Double(k) / Double(n)
            var re = 0.0, im = 0.0
            for j in 0..<n {
                let angle = step * Double(j)
                re += y[j] * cos(angle)
                im += y[j] * sin(angle)
            }
            let power = re * re + im * im
            total += power
            peak = max(peak, power)
        }
        if total == 0 { return nil }
        return peak / total
    }

    // MARK: Scoring and filter

    private struct Scaler {
        let mean: Double
        let deviation: Double

        init(_ values: [Double]) {
            guard !values.isEmpty else {
                mean = 0
                deviation = 1
                return
            }
            let average = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)
            let spread = variance.squareRoot()
            mean = average
            deviation = spread == 0 ? 1 : spread
        }

        func z(_ value: Double?) -> Double {
            guard let value else { return 0 }
            return (value - mean) / deviation
        }
    }

    // V2 constants, order deep / rem / light / awake. `SleepStagerV2.baseLogPrior`, `transition`.
    private static let logPrior: [Double] = [log(0.15), log(0.22), log(0.50), log(0.10)]
    private static let transition: [[Double]] = [
        [0.86, 0.007, 0.126, 0.007],
        [0.005, 0.88, 0.10, 0.015],
        [0.06, 0.06, 0.85, 0.03],
        [0.0, 0.0, 0.10, 0.90],
    ]

    /// Log emission scores for one epoch, deep / rem / light / awake. V2's `stageEpochs` without the motion terms.
    /// `cycleFraction` is the position in the night (0...1); `zRegularity` is nil when the respiration term is unused.
    static func logEmissions(
        zHeartRate: Double,
        zVariability: Double,
        flatnessPercentile: Double,
        cycleFraction: Double,
        zRegularity: Double?
    ) -> [Double] {
        let gate = 5.0 * max(0, flatnessPercentile - 0.25)
        var deep = -1.1 * zVariability - gate + logPrior[0] + 1.2 * max(0, 1 - cycleFraction / 0.55)
        var rem = 0.6 * zVariability + 0.4 * zHeartRate + logPrior[1] + cycleFraction
        let light = logPrior[2]
        // No motion: V2 keeps only the sleep-suppressing half of the cardiac awake term.
        let awake = min(0, 0.8 * zVariability + 0.4 * zHeartRate) + logPrior[3]
        if let zRegularity {
            deep += 0.6 * zRegularity
            rem -= 0.6 * zRegularity
        }
        return [deep, rem, light, awake]
    }

    /// One step of the forward filter. `belief` is the previous posterior (nil: start from V2's priors).
    static func forwardStep(belief: [Double]?, logEmissions: [Double]) -> [Double] {
        let prior = belief ?? {
            let raw = logPrior.map { exp($0) }
            let sum = raw.reduce(0, +)
            return raw.map { $0 / sum }
        }()
        let strongest = logEmissions.max() ?? 0
        var posterior = [Double](repeating: 0, count: 4)
        for j in 0..<4 {
            var predicted = 0.0
            for i in 0..<4 { predicted += prior[i] * max(transition[i][j], 1e-9) }
            posterior[j] = predicted * exp(logEmissions[j] - strongest)
        }
        let total = posterior.reduce(0, +)
        guard total > 0 else { return prior }
        return posterior.map { $0 / total }
    }

    private mutating func advanceFilter(with epoch: ClosedEpoch, epochStart: Double) -> [Double] {
        let heartRates = Scaler(history.compactMap(\.heartRate))
        let variabilities = Scaler(history.compactMap(\.variability))
        let respirations = history.compactMap(\.respiration)
        let regularity = Scaler(respirations)
        let sortedFlatness = history.compactMap(\.flatness).sorted()

        var percentile = 0.5
        if let flatness = epoch.flatness, !sortedFlatness.isEmpty {
            var low = 0, high = sortedFlatness.count
            while low < high {
                let middle = (low + high) / 2
                if sortedFlatness[middle] <= flatness { low = middle + 1 } else { high = middle }
            }
            percentile = Double(low) / Double(sortedFlatness.count)
        }

        let middle = epochStart + configuration.epochSeconds / 2
        let remaining = maximumWakeTime.timeIntervalSince1970 - middle
        let fraction = min(1, max(0, 1 - remaining / configuration.assumedNightSeconds))

        var zRegularity: Double?
        if let value = epoch.respiration, respirations.count >= configuration.respirationMinimumReference {
            zRegularity = regularity.z(value)
        }
        let scores = Self.logEmissions(
            zHeartRate: heartRates.z(epoch.heartRate),
            zVariability: variabilities.z(epoch.variability),
            flatnessPercentile: percentile,
            cycleFraction: fraction,
            zRegularity: zRegularity
        )
        let posterior = Self.forwardStep(belief: belief, logEmissions: scores)
        belief = posterior
        return posterior
    }
}
