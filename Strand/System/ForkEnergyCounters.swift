import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
        // Where the process CPU went, by thread (sampled with cpuProcessMs): main thread, threads whose name says
        // "cooperative" (workers), other GCD root-queue threads, other named threads, unnamed threads, and threads that ended between two samples.
        // They add up to cpuProcessMs, so the part the phases above do not explain is read off these.
        case cpuThrMainMs, cpuThrWorkersMs, cpuThrDispatchMs, cpuThrNamedMs, cpuThrUnnamedMs, cpuThrExitedMs
        // Re-score passes that returned at a gate (nothing new since the last run); their CPU is not in cpuRescoreMs.
        case rescoreGateSkipped
        // The Night card: its load task started, its load finished, its content appeared on screen.
        case nightCardTask, nightCardLoaded, nightCardShown
        // Offload widget publishes skipped because nothing new was banked.
        case widgetPublishSkipped
        // Widget reloads by the field that caused them (one reason per reload, first match in this order), the saves
        // that asked for none, and the reloads that do not go through `widgetReload` (NOOP+ widget, coach brief).
        case widgetReloadLive, widgetReloadScore, widgetReloadStress, widgetReloadBonded, widgetReloadLowBatt
        case widgetSavedNoReload, widgetReloadFork, widgetReloadCoach
        // Widget publishes by call site: every full publish, every live-only publish, and the three background callers.
        case widgetPublishTotal, widgetPublishLive, widgetPublishPostOffload, widgetPublishResume, widgetPublishBackground
        // Re-score passes that ran, by trigger, with the process CPU each took (Resume = the deferred background pass).
        case rescoreIdle, rescoreIdleMs, rescorePostOffload, rescorePostOffloadMs
        case rescoreForced, rescoreForcedMs, rescoreResume, rescoreResumeMs
        // Days of those passes served from the per-day cache versus scored again.
        case rescoreDaysCached, rescoreDaysScored
        // Live heart rate on the main thread: samples ingested, smoothed values published, LiveState change notices.
        case hrSamples, bpmPublished, liveWillChange
        // SwiftUI body evaluations of the main screens while the app was not active.
        case uiBodyBg
        // Inbound BLE notifications (all, and those on the data characteristic), strap-log lines and their main-thread ms.
        case bleFrames, bleRawFrames, logLines, logAppendMs
    }

    /// Process CPU time so far, milliseconds (user + system), 0 when the system call fails.
    static func cpuNowMillis() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func ms(_ t: timeval) -> Int { Int(t.tv_sec) * 1000 + Int(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    // MARK: Thread attribution (TEMP)

    struct ThreadSlice: Equatable {
        let id: UInt64
        let name: String
        let cpuMs: Int
        let isMain: Bool
    }

    /// The bucket a thread's CPU is booked to. Names only: no memory of a dispatch queue is dereferenced.
    static func bucket(threadName: String, isMain: Bool) -> Counter {
        if isMain { return .cpuThrMainMs }
        if threadName.isEmpty { return .cpuThrUnnamedMs }
        if threadName.contains("cooperative") { return .cpuThrWorkersMs }
        if threadName.hasPrefix("com.apple.root.") { return .cpuThrDispatchMs }
        return .cpuThrNamedMs
    }

    /// CPU per bucket since the previous sample, and the part of `processDelta` that live threads do not explain
    /// (threads that ended in between). A thread first seen now counts in full.
    static func attribute(slices: [ThreadSlice], previous: [UInt64: Int],
                          processDelta: Int) -> (byBucket: [Counter: Int], exited: Int) {
        var byBucket: [Counter: Int] = [:]
        var live = 0
        for slice in slices {
            let delta = max(0, slice.cpuMs - (previous[slice.id] ?? 0))
            live += delta
            byBucket[bucket(threadName: slice.name, isMain: slice.isMain), default: 0] += delta
        }
        return (byBucket, max(0, processDelta - live))
    }

    /// Every thread of this process with its CPU time and name. The first thread the kernel lists is the main thread.
    static func threadSlices() -> [ThreadSlice] {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var out: [ThreadSlice] = []
        for index in 0..<Int(count) {
            let thread = list[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }

            var basic = thread_basic_info()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let basicOK = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            } == KERN_SUCCESS

            var ident = thread_identifier_info()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
            let identOK = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            } == KERN_SUCCESS

            var ext = thread_extended_info()
            var extCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
            let extOK = withUnsafeMutablePointer(to: &ext) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extCount)
                }
            } == KERN_SUCCESS

            guard basicOK, identOK else { continue }
            func ms(_ t: time_value_t) -> Int { Int(t.seconds) * 1000 + Int(t.microseconds) / 1000 }
            var name = ""
            if extOK {
                name = withUnsafePointer(to: &ext.pth_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXTHREADNAMESIZE)) { String(cString: $0) }
                }
            }
            out.append(ThreadSlice(id: ident.thread_id, name: name,
                                   cpuMs: ms(basic.user_time) + ms(basic.system_time), isMain: index == 0))
        }
        return out
    }

    /// Add the CPU spent since `startMillis` to a phase counter.
    func noteCPU(_ counter: Counter, since startMillis: Int, at now: Date = Date()) {
        note(counter, by: max(0, Self.cpuNowMillis() - startMillis), at: now)
    }

    /// One inbound BLE notification. `isData`: it arrived on the data characteristic (raw stream and history offload).
    func noteBLEFrame(isData: Bool) {
        note(.bleFrames)
        if isData { note(.bleRawFrames) }
    }

    private var logAppendRemainderUs = 0

    /// One strap-log line that started at `start` (uptime ns) and has just ended; whole milliseconds are booked, the rest carries.
    func noteLogLine(sinceNanos start: UInt64) {
        let micros = Int(DispatchTime.now().uptimeNanoseconds &- start) / 1000
        note(.logLines)
        lock.lock()
        logAppendRemainderUs += micros
        let whole = logAppendRemainderUs / 1000
        logAppendRemainderUs %= 1000
        lock.unlock()
        if whole > 0 { note(.logAppendMs, by: whole) }
    }

    /// A body evaluation of a main screen (main thread); counted only while the app is not in the foreground.
    /// Always 0 on macOS, where there is no background state to ask about.
    @MainActor
    static func noteBodyEvaluated() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        if UIApplication.shared.applicationState != .active { shared.note(.uiBodyBg) }
        #endif
        return true
    }

    /// The counters a re-score pass books, by its trigger label (`idle`, `post-offload`, `forced`, `resume-…`).
    static func rescoreCounters(trigger: String) -> (runs: Counter, ms: Counter) {
        if trigger == "idle" { return (.rescoreIdle, .rescoreIdleMs) }
        if trigger == "post-offload" { return (.rescorePostOffload, .rescorePostOffloadMs) }
        if trigger.hasPrefix("resume") { return (.rescoreResume, .rescoreResumeMs) }
        return (.rescoreForced, .rescoreForcedMs)
    }

    func noteRescore(trigger: String, cpuSince startMillis: Int, at now: Date = Date()) {
        let pair = Self.rescoreCounters(trigger: trigger)
        note(pair.runs, at: now)
        noteCPU(pair.ms, since: startMillis, at: now)
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
    private var lastThreadCPU: [UInt64: Int] = [:]
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
            let slices = Self.threadSlices()
            if lastCPUSample != .distantPast, cpu >= lastCPUMillis {
                hours[key, default: [:]][Counter.cpuProcessMs.rawValue, default: 0] += cpu - lastCPUMillis
                let split = Self.attribute(slices: slices, previous: lastThreadCPU, processDelta: cpu - lastCPUMillis)
                for (counter, ms) in split.byBucket where ms > 0 {
                    hours[key, default: [:]][counter.rawValue, default: 0] += ms
                }
                if split.exited > 0 { hours[key, default: [:]][Counter.cpuThrExitedMs.rawValue, default: 0] += split.exited }
            }
            lastThreadCPU = Dictionary(slices.map { ($0.id, $0.cpuMs) }, uniquingKeysWith: { _, last in last })
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
