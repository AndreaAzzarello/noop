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

    private mutating func fire(_ reason: SmartWakeTrigger) -> SmartWakeDecision {
        trigger = reason
        return .wake(reason)
    }
}
