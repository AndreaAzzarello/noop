import Foundation

/// Pure, deterministic heart-rate heuristic for the iOS Smart Wake prototype.
///
/// This is deliberately not a sleep-stage classifier. It looks for a sustained rise
/// above a robust pre-window baseline and never treats missing/poor data as a reason
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
    let requiredElevatedSamples: Int
    let minimumRiseDuration: TimeInterval
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
    private var elevatedSamples: [SmartWakeHeartRateSample] = []
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

        if let previous = elevatedSamples.last {
            guard sample.timestamp > previous.timestamp else { return .waiting }
            if sample.timestamp.timeIntervalSince(previous.timestamp) > configuration.maximumSampleGap {
                elevatedSamples.removeAll(keepingCapacity: true)
            }
        }

        let isElevated = Double(sample.bpm) >= baselineMedianBPM + configuration.riseThresholdBPM
        guard isElevated else {
            elevatedSamples.removeAll(keepingCapacity: true)
            return .waiting
        }

        elevatedSamples.append(sample)
        if elevatedSamples.count > configuration.requiredElevatedSamples {
            elevatedSamples.removeFirst(elevatedSamples.count - configuration.requiredElevatedSamples)
        }

        guard elevatedSamples.count == configuration.requiredElevatedSamples,
              let first = elevatedSamples.first,
              let last = elevatedSamples.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= configuration.minimumRiseDuration
        else {
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
