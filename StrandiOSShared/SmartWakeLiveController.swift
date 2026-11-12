import Foundation

/// Daily Smart Wake schedule. Its maximum time, weekdays, and per-day overrides mirror
/// the existing WHOOP alarm settings; the early window is independently adjustable.
struct SmartWakeSchedule: Equatable, Codable {
    let wakeMinutes: Int
    let weekdays: Set<Int>
    let overrides: [Int: Int]
    let windowDuration: TimeInterval
    let baselineLookback: TimeInterval

    static let standard = SmartWakeSchedule(
        wakeMinutes: 7 * 60,
        windowDuration: 30 * 60,
        baselineLookback: 60 * 60
    )

    init(
        wakeMinutes: Int = 7 * 60,
        weekdays: Set<Int> = [],
        overrides: [Int: Int] = [:],
        windowDuration: TimeInterval = 30 * 60,
        baselineLookback: TimeInterval = 60 * 60
    ) {
        self.wakeMinutes = min(max(wakeMinutes, 0), 24 * 60 - 1)
        self.weekdays = Set(weekdays.filter { (1...7).contains($0) })
        self.overrides = overrides.filter {
            (1...7).contains($0.key) && (0..<24 * 60).contains($0.value)
        }
        self.windowDuration = min(max(0, windowDuration), 3 * 60 * 60)
        self.baselineLookback = min(max(0, baselineLookback), 6 * 60 * 60)
    }

    /// Compatibility initializer for deterministic tests and explicit time-of-day schedules.
    init(
        wakeHour: Int,
        wakeMinute: Int,
        windowDuration: TimeInterval = 30 * 60,
        baselineLookback: TimeInterval = 60 * 60
    ) {
        self.init(
            wakeMinutes: min(max(wakeHour, 0), 23) * 60 + min(max(wakeMinute, 0), 59),
            windowDuration: windowDuration,
            baselineLookback: baselineLookback
        )
    }

    func isEnabled(onWeekday weekday: Int) -> Bool {
        weekdays.isEmpty || weekdays.contains(weekday)
    }

    func wakeMinutes(onWeekday weekday: Int) -> Int {
        overrides[weekday] ?? wakeMinutes
    }

    func nextMaximumWakeTime(after date: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let candidate = maximumWakeTime(on: day, calendar: calendar),
                  candidate > date
            else { continue }
            return candidate
        }
        return nil
    }

    func maximumWakeTime(on day: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: day)
        guard isEnabled(onWeekday: weekday) else { return nil }
        let minutes = wakeMinutes(onWeekday: weekday)
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }
}

/// Connects readable WHOOP HR notifications to the pure Smart Wake detector.
///
/// The short HR baseline is retained locally across process restarts and midnight. If it is
/// unavailable or incomplete, early wake is disabled for that cycle; the separately scheduled
/// AlarmKit deadline remains the fail-safe.
final class SmartWakeLiveController {
    private let calendar: Calendar
    private let defaults: UserDefaults
    private static let baselineStorageKey = "smartWake.localBaseline.v1"
    private let maximumBufferedSamples = 4_000
    private let persistenceInterval: TimeInterval = 30

    private(set) var schedule: SmartWakeSchedule
    private var activeDay: Date?
    private var maximumWakeTime: Date?
    private var baselineSamples: [SmartWakeHeartRateSample] = []
    private var lastReceivedTimestamp: Date?
    private var lastPersistedTimestamp: Date?
    private var engine: SmartWakeEngine

    private(set) var latestDecision: SmartWakeDecision = .waiting
    private var engineNotStarted = true

    init(
        schedule: SmartWakeSchedule = .standard,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) {
        self.calendar = calendar
        self.defaults = defaults
        self.schedule = schedule
        let loadedBaseline = Self.loadBaseline(from: defaults, key: Self.baselineStorageKey)
        self.baselineSamples = loadedBaseline
        self.lastReceivedTimestamp = loadedBaseline.last?.timestamp
        self.engine = SmartWakeEngine(
            configuration: .standard(maximumWakeTime: .distantFuture),
            baselineSamples: []
        )
    }

    func updateSchedule(_ schedule: SmartWakeSchedule) {
        guard self.schedule != schedule else { return }
        self.schedule = schedule
        activeDay = nil
        maximumWakeTime = nil
        engineNotStarted = true
        latestDecision = .waiting
    }

    @discardableResult
    func ingest(bpm: Int, at timestamp: Date) -> SmartWakeDecision {
        guard (30...220).contains(bpm) else { return latestDecision }
        prepareDay(containing: timestamp)

        // Ignore duplicate or out-of-order notifications rather than biasing the baseline.
        if let lastReceivedTimestamp, timestamp <= lastReceivedTimestamp {
            return latestDecision
        }
        lastReceivedTimestamp = timestamp

        let sample = SmartWakeHeartRateSample(bpm: bpm, timestamp: timestamp)
        guard let maximumWakeTime else {
            appendBaselineSample(sample, retainingFrom: timestamp.addingTimeInterval(-max(2 * 60 * 60, schedule.baselineLookback)))
            return latestDecision
        }

        let windowStart = maximumWakeTime.addingTimeInterval(-schedule.windowDuration)
        if timestamp < windowStart {
            appendBaselineSample(
                sample,
                retainingFrom: windowStart.addingTimeInterval(-schedule.baselineLookback)
            )
            return latestDecision
        }

        if engineNotStarted {
            engine = makeEngine(maximumWakeTime: maximumWakeTime)
            engineNotStarted = false
        }

        latestDecision = engine.ingest(sample, at: timestamp)
        return latestDecision
    }

    /// Allows deterministic tests and foreground reconciliation to evaluate the hard deadline.
    /// The real deadline is independently enforced by AlarmKit, not by an in-process timer.
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
        let windowStart = maximumWakeTime.addingTimeInterval(-schedule.windowDuration)
        let baselineStart = windowStart.addingTimeInterval(-schedule.baselineLookback)
        let relevantBaseline = baselineSamples.filter {
            $0.timestamp >= baselineStart && $0.timestamp < windowStart
        }
        return SmartWakeEngine(
            configuration: .standard(
                maximumWakeTime: maximumWakeTime,
                windowDuration: schedule.windowDuration
            ),
            baselineSamples: relevantBaseline
        )
    }

    private func prepareDay(containing date: Date) {
        let dayStart = calendar.startOfDay(for: date)
        guard activeDay != dayStart else { return }

        activeDay = dayStart
        maximumWakeTime = schedule.nextMaximumWakeTime(after: date, calendar: calendar)
        engineNotStarted = true
        latestDecision = .waiting

        // Keep enough prior-day data for a window that crosses midnight.
        let retention = max(2 * 60 * 60, schedule.windowDuration + schedule.baselineLookback)
        let cutoff = date.addingTimeInterval(-retention)
        baselineSamples.removeAll { $0.timestamp < cutoff }
        lastReceivedTimestamp = baselineSamples.last?.timestamp
        persistBaselineIfNeeded(at: date, force: true)

        if let maximumWakeTime {
            engine = makeEngine(maximumWakeTime: maximumWakeTime)
        }
    }

    private func appendBaselineSample(_ sample: SmartWakeHeartRateSample, retainingFrom cutoff: Date) {
        baselineSamples.append(sample)
        baselineSamples.removeAll { $0.timestamp < cutoff }
        if baselineSamples.count > maximumBufferedSamples {
            baselineSamples.removeFirst(baselineSamples.count - maximumBufferedSamples)
        }
        persistBaselineIfNeeded(at: sample.timestamp)
    }

    private func persistBaselineIfNeeded(at date: Date, force: Bool = false) {
        if let lastPersistedTimestamp,
           !force,
           date.timeIntervalSince(lastPersistedTimestamp) < persistenceInterval {
            return
        }
        guard let data = try? JSONEncoder().encode(baselineSamples) else { return }
        defaults.set(data, forKey: Self.baselineStorageKey)
        lastPersistedTimestamp = date
    }

    private static func loadBaseline(from defaults: UserDefaults, key: String) -> [SmartWakeHeartRateSample] {
        guard let data = defaults.data(forKey: key),
              let samples = try? JSONDecoder().decode([SmartWakeHeartRateSample].self, from: data)
        else { return [] }
        return Array(samples
            .filter { (30...220).contains($0.bpm) }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(4_000))
    }
}
