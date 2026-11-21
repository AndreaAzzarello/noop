import Foundation

// fork-perf: TEMP — energy audit counters. Remove with `git revert` of the "perf(temp): energy counters" commit.

/// Per-hour counts and durations of the work that can wake the phone or write to Apple Health.
///
/// Counts and milliseconds only. The closed `Counter` set below is the whole vocabulary, so a health value,
/// a timestamp of a sample or an identifier cannot reach the file by construction.
///
/// Kept in `Strand/System` (shared target) so `StrandTests` can reach it; the callers are in both targets.
final class ForkEnergyCounters: @unchecked Sendable {

    enum Counter: String, CaseIterable, Codable {
        case offloadCompleted, bleReconnect
        case hkObserverWake, hkObserverEmptyWake, hkObserverCoalesced
        case hkSync, hkSyncMs
        case writeBack, writeBackMs
        case hkVitalsWritten, hkVitalsDeleted
        case hkSleepWritten, hkSleepDeleted
        case hkHeartRateWritten, hkHeartRateDeleted
        case hkWorkoutsWritten, hkWorkoutsDeleted
        case ledgerSkippedKeys, ledgerRewrittenKeys, ledgerFullRewrite, ledgerInvalidated
        case hkDeleteFailed, hkSaveFailed
        case fgSyncRun, fgSyncSkipped
        case bgHealthWriteback, bgCoachBrief, bgDebugExport, bgRescore, bgStaleBattery
        case watchPush, widgetReload
        case watchContextReceived, watchContextDuplicate, watchComplicationReload
        case watchWorkoutStart, watchWorkoutEnd, watchWorkoutRecovered
        case watchHrQueryStart, watchHrQueryStop, watchAppLaunch
        // Process CPU milliseconds (user + system) spent while a phase ran. Concurrent work of other phases is
        // included, so a phase reads as an upper bound; cpuProcessMs is the sampled total, and what the phases do
        // not add up to is the rest (BLE streaming, UI, system frameworks).
        case cpuProcessMs, cpuOffloadMs, cpuRefreshMs, cpuRescoreMs, cpuWriteBackMs, cpuWidgetMs
        // The Night card: its load task started, its load finished, its content appeared on screen.
        case nightCardTask, nightCardLoaded, nightCardShown
        // Offload widget publishes skipped because nothing new was banked.
        case widgetPublishSkipped
    }

    /// Process CPU time so far, milliseconds (user + system), 0 when the system call fails.
    static func cpuNowMillis() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func ms(_ t: timeval) -> Int { Int(t.tv_sec) * 1000 + Int(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    /// Add the CPU spent since `startMillis` to a phase counter.
    func noteCPU(_ counter: Counter, since startMillis: Int, at now: Date = Date()) {
        note(counter, by: max(0, Self.cpuNowMillis() - startMillis), at: now)
    }

    static let shared = ForkEnergyCounters(fileURL: ForkEnergyCounters.defaultFileURL())

    /// Hours kept on disk: 7 days.
    static let keptHours = 7 * 24
    /// Minimum spacing between disk writes, seconds.
    static let flushInterval: TimeInterval = 60

    private let lock = NSLock()
    private let fileURL: URL?
    private let timeZone: TimeZone
    private var hours: [String: [String: Int]] = [:]   // "yyyy-MM-dd HH" → counter raw value → count
    private var dirty = false
    private var lastFlush = Date.distantPast
    private var loaded = false
    private var lastCPUSample = Date.distantPast
    private var lastCPUMillis = 0
    static let cpuSampleInterval: TimeInterval = 300

    init(fileURL: URL?, timeZone: TimeZone = .current) {
        self.fileURL = fileURL
        self.timeZone = timeZone
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ForkPerf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("energy-counters.json")
    }

    /// `yyyy-MM-dd HH` in the counter's time zone.
    static func bucket(for date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d %02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }

    func note(_ counter: Counter, by amount: Int = 1, at now: Date = Date()) {
        guard amount != 0 else { return }
        lock.lock()
        loadIfNeeded()
        let key = Self.bucket(for: now, timeZone: timeZone)
        hours[key, default: [:]][counter.rawValue, default: 0] += amount
        // The process CPU total is sampled at most every 5 minutes and booked to the hour of the sample.
        if now.timeIntervalSince(lastCPUSample) >= Self.cpuSampleInterval {
            let cpu = Self.cpuNowMillis()
            if lastCPUSample != .distantPast, cpu >= lastCPUMillis {
                hours[key, default: [:]][Counter.cpuProcessMs.rawValue, default: 0] += cpu - lastCPUMillis
            }
            lastCPUMillis = cpu
            lastCPUSample = now
        }
        dirty = true
        let due = now.timeIntervalSince(lastFlush) >= Self.flushInterval
        if due { flushLocked(now: now) }
        lock.unlock()
    }

    /// Duration helper: one event plus its milliseconds.
    func note(_ event: Counter, millis: Counter, since start: Date, at now: Date = Date()) {
        note(event, at: now)
        note(millis, by: max(0, Int(now.timeIntervalSince(start) * 1000)), at: now)
    }

    /// Write now (app going to background, or the report being exported).
    func flush(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        flushLocked(now: now)
    }

    /// Test seam.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        hours = [:]; dirty = false; loaded = true
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func snapshot() -> [String: [String: Int]] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return hours
    }

    /// Plain-text report: per-day totals, then the last `lastHours` hours that have any count.
    func report(lastHours: Int = 24) -> String {
        let data = snapshot()
        guard !data.isEmpty else { return "Energy counters: nothing recorded yet." }
        var lines = ["Energy counters (counts and milliseconds only)"]
        var perDay: [String: [String: Int]] = [:]
        for (hour, counts) in data {
            let day = String(hour.prefix(10))
            for (k, v) in counts { perDay[day, default: [:]][k, default: 0] += v }
        }
        for day in perDay.keys.sorted() {
            lines.append("\(day) total: " + Self.format(perDay[day] ?? [:]))
        }
        lines.append("— last \(lastHours) h —")
        for hour in data.keys.sorted().suffix(lastHours) {
            lines.append("\(hour)h: " + Self.format(data[hour] ?? [:]))
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ counts: [String: Int]) -> String {
        let order = Counter.allCases.map(\.rawValue)
        return order.compactMap { name in counts[name].map { "\(name)=\($0)" } }.joined(separator: " ")
    }

    // MARK: - Persistence (lock held)

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else { return }
        // Merge: counts noted before the first load are already in `hours`.
        for (hour, counts) in decoded {
            for (k, v) in counts { hours[hour, default: [:]][k, default: 0] += v }
        }
    }

    private func flushLocked(now: Date) {
        loadIfNeeded()
        guard dirty, let fileURL else { return }
        if hours.count > Self.keptHours {
            for key in hours.keys.sorted().dropLast(Self.keptHours) { hours[key] = nil }
        }
        guard let data = try? JSONEncoder().encode(hours) else { return }
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
        lastFlush = now
    }
}
