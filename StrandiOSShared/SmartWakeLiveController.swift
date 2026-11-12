import Foundation

/// Connects readable WHOOP HR notifications to the pure Smart Wake detector.
///
/// This controller only evaluates and records decisions. It deliberately does not schedule
/// notifications, play haptics, or alter the existing alarm. iOS may suspend the process, so
/// samples are event-driven and cannot be assumed continuous.
final class SmartWakeLiveController {
    private let calendar: Calendar
    private let maximumWakeHour = 7
    private let maximumWakeMinute = 20
    private let windowDuration: TimeInterval = 30 * 60
    private let baselineLookback: TimeInterval = 60 * 60
    private let maximumBufferedSamples = 4_000

    private var activeDay: Date?
    private var maximumWakeTime: Date?
    private var baselineSamples: [SmartWakeHeartRateSample] = []
    private var lastReceivedTimestamp: Date?
    private var engine: SmartWakeEngine

    private(set) var latestDecision: SmartWakeDecision = .waiting

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.engine = SmartWakeEngine(
            configuration: .standard(maximumWakeTime: .distantFuture),
            baselineSamples: []
        )
    }

    @discardableResult
    func ingest(bpm: Int, at timestamp: Date) -> SmartWakeDecision {
        guard (30...220).contains(bpm) else { return latestDecision }
        prepareDay(containing: timestamp)

        // Ignore duplicate or out-of-order notifications rather than letting them bias the baseline.
        if let lastReceivedTimestamp, timestamp <= lastReceivedTimestamp {
            return latestDecision
        }
        lastReceivedTimestamp = timestamp

        guard let maximumWakeTime else { return latestDecision }
        let windowStart = maximumWakeTime.addingTimeInterval(-windowDuration)
        let sample = SmartWakeHeartRateSample(bpm: bpm, timestamp: timestamp)

        if timestamp < windowStart {
            baselineSamples.append(sample)
            let cutoff = timestamp.addingTimeInterval(-baselineLookback)
            baselineSamples.removeAll { $0.timestamp < cutoff }
            if baselineSamples.count > maximumBufferedSamples {
                baselineSamples.removeFirst(baselineSamples.count - maximumBufferedSamples)
            }
            return latestDecision
        }

        if engineNotStarted {
            engine = SmartWakeEngine(
                configuration: .standard(maximumWakeTime: maximumWakeTime),
                baselineSamples: baselineSamples
            )
            engineNotStarted = false
        }

        latestDecision = engine.ingest(sample, at: timestamp)
        return latestDecision
    }

    /// Allows a future scheduler to evaluate the hard deadline without needing another HR sample.
    /// This is intentionally not wired to an alarm or timer in this integration step.
    @discardableResult
    func evaluate(at date: Date) -> SmartWakeDecision {
        prepareDay(containing: date)
        guard let maximumWakeTime else { return latestDecision }
        if engineNotStarted {
            engine = SmartWakeEngine(
                configuration: .standard(maximumWakeTime: maximumWakeTime),
                baselineSamples: baselineSamples
            )
            engineNotStarted = false
        }
        latestDecision = engine.evaluate(at: date)
        return latestDecision
    }

    private var engineNotStarted = true

    private func prepareDay(containing date: Date) {
        let dayStart = calendar.startOfDay(for: date)
        guard activeDay != dayStart else { return }

        activeDay = dayStart
        var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        components.hour = maximumWakeHour
        components.minute = maximumWakeMinute
        components.second = 0
        maximumWakeTime = calendar.date(from: components)
        baselineSamples.removeAll(keepingCapacity: true)
        lastReceivedTimestamp = nil
        engineNotStarted = true
        latestDecision = .waiting
        if let maximumWakeTime {
            engine = SmartWakeEngine(
                configuration: .standard(maximumWakeTime: maximumWakeTime),
                baselineSamples: []
            )
        }
    }
}
