import Foundation

/// User-adjustable schedule for the daily Smart Wake cycle.
/// The 07:20 / 30-minute values are defaults only, not detector assumptions.
struct SmartWakeSchedule: Equatable {
    let wakeHour: Int
    let wakeMinute: Int
    let windowDuration: TimeInterval
    let baselineLookback: TimeInterval

    static let standard = SmartWakeSchedule(
        wakeHour: 7,
        wakeMinute: 20,
        windowDuration: 30 * 60,
        baselineLookback: 60 * 60
    )

    init(
        wakeHour: Int,
        wakeMinute: Int,
        windowDuration: TimeInterval = 30 * 60,
        baselineLookback: TimeInterval = 60 * 60
    ) {
        self.wakeHour = min(max(wakeHour, 0), 23)
        self.wakeMinute = min(max(wakeMinute, 0), 59)
        self.windowDuration = max(0, windowDuration)
        self.baselineLookback = max(0, baselineLookback)
    }

    func maximumWakeTime(on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = wakeHour
        components.minute = wakeMinute
        components.second = 0
        return calendar.date(from: components)
    }
}

/// Connects readable WHOOP HR notifications to the pure Smart Wake detector.
///
/// This controller only evaluates and records decisions. It deliberately does not schedule
/// notifications, play haptics, or alter the existing alarm. iOS may suspend the process, so
/// samples are event-driven and cannot be assumed continuous.
final class SmartWakeLiveController {
    private let calendar: Calendar
    private let schedule: SmartWakeSchedule
    private let maximumBufferedSamples = 4_000

    private var activeDay: Date?
    private var maximumWakeTime: Date?
    private var baselineSamples: [SmartWakeHeartRateSample] = []
    private var lastReceivedTimestamp: Date?
    private var engine: SmartWakeEngine

    private(set) var latestDecision: SmartWakeDecision = .waiting
    private var engineNotStarted = true

    init(
        schedule: SmartWakeSchedule = .standard,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar
        self.schedule = schedule
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
        let windowStart = maximumWakeTime.addingTimeInterval(-schedule.windowDuration)
        let sample = SmartWakeHeartRateSample(bpm: bpm, timestamp: timestamp)

        if timestamp < windowStart {
            baselineSamples.append(sample)
            let cutoff = timestamp.addingTimeInterval(-schedule.baselineLookback)
            baselineSamples.removeAll { $0.timestamp < cutoff }
            if baselineSamples.count > maximumBufferedSamples {
                baselineSamples.removeFirst(baselineSamples.count - maximumBufferedSamples)
            }
            return latestDecision
        }

        if engineNotStarted {
            engine = makeEngine(maximumWakeTime: maximumWakeTime)
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
            engine = makeEngine(maximumWakeTime: maximumWakeTime)
            engineNotStarted = false
        }
        latestDecision = engine.evaluate(at: date)
        return latestDecision
    }

    private func makeEngine(maximumWakeTime: Date) -> SmartWakeEngine {
        SmartWakeEngine(
            configuration: .standard(
                maximumWakeTime: maximumWakeTime,
                windowDuration: schedule.windowDuration
            ),
            baselineSamples: baselineSamples
        )
    }

    private func prepareDay(containing date: Date) {
        let dayStart = calendar.startOfDay(for: date)
        guard activeDay != dayStart else { return }

        activeDay = dayStart
        maximumWakeTime = schedule.maximumWakeTime(on: dayStart, calendar: calendar)
        baselineSamples.removeAll(keepingCapacity: true)
        lastReceivedTimestamp = nil
        engineNotStarted = true
        latestDecision = .waiting
        if let maximumWakeTime {
            engine = makeEngine(maximumWakeTime: maximumWakeTime)
        }
    }
}
