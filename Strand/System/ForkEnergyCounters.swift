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
        // The same sample read against the REAL main thread (the mach port captured on the main thread itself), not
        // "the first thread of task_threads": its CPU, the samples where the first thread was not the main one, and
        // the samples taken before the main thread was captured. `cpuThrMainMs` stays as it was, to compare a day.
        case cpuThrMainRealMs, mainThreadMismatch, mainThreadUnknown
        // Main run-loop iterations (`ForkRunLoopMeter`): count in the foreground and in the background, by thread-CPU band
        // (<1, 1-10, 10-100, >100 ms), their total CPU ms, the part in iterations a BLE call site touched, the part in
        // the background, and the LiveState change notices that fell inside iterations.
        case rlIterFg, rlIterBg, rlBandLt1, rlBand1to10, rlBand10to100, rlBandGt100
        case rlCpuMs, rlCpuBleMs, rlCpuBgMs, rlWillChange
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
        // NOOP+ reloads (`widgetReloadFork`) by reason, and the saves whose reload the background interval held back.
        case widgetReloadForkFirst, widgetReloadForkSmartWake, widgetReloadForkFormat, widgetReloadForkDay
        case widgetReloadForkContent, widgetReloadForkStale, widgetReloadForkOwed, widgetReloadForkDeferred
        // Widget publishes by call site: every full publish, every live-only publish, and the three background callers.
        case widgetPublishTotal, widgetPublishLive, widgetPublishPostOffload, widgetPublishResume, widgetPublishBackground
        // Re-score passes that ran, by trigger, with the process CPU each took (Resume = the deferred background pass).
        case rescoreIdle, rescoreIdleMs, rescorePostOffload, rescorePostOffloadMs
        case rescoreForced, rescoreForcedMs, rescoreResume, rescoreResumeMs
        // Days of those passes served from the per-day cache versus scored again.
        case rescoreDaysCached, rescoreDaysScored
        // Where a re-score pass that worked spent its time. Process CPU ms, so concurrent work of other threads is in each
        // figure: before the day loop; per day, the owner and cache-key reads, the stream reads (prep) and `analyzeDay`
        // (score); the loop's remainder and the CPU spent while it paced itself in the background (all other threads); after
        // the loop. `rescoreScoreThrMs` is the CPU of the thread that ran `analyzeDay`, so score minus it is what the rest of
        // the process did meanwhile. `rescoreWallMs` is the wall time of the passes (uptime, gates included).
        case rescorePreMs, rescoreKeyMs, rescorePrepMs, rescoreScoreMs, rescoreScoreThrMs
        case rescoreLoopRestMs, rescorePaceMs, rescorePostMs, rescoreWallMs
        // The MAIN thread's CPU while the key, prep and post phases ran (thread CPU, valid across awaits). The phase
        // figures above are process CPU and include it, so `rescoreKeyMs - rescoreKeyMainMs` is what the pass itself cost.
        case rescoreKeyMainMs, rescorePrepMainMs, rescorePostMainMs
        // Main-thread CPU by call site (`ForkMainCPU`), thread-CPU ms, EXCLUSIVE: a point's figure leaves out the points it
        // called, so they add up. `cpuThrMainMs` minus their sum is what no point explains.
        case mainBleNotifyMs, mainBleRouterMs, mainBleStdHRMs, mainBleCollectorMs, mainBleSmartWakeMs
        case mainIngestHRMs, mainLogMs, mainOffloadMs, mainSinksMs
        // Inbound BLE frames by class, count and bytes: standard heart rate (per notification), raw type 43, realtime
        // type 40, history offload (types 47/48/49/50/56) and the rest (per complete frame).
        case bleFrameStdHR, bleFrameStdHRBytes, bleFrameRaw43, bleFrameRaw43Bytes
        case bleFrameRealtime40, bleFrameRealtime40Bytes, bleFrameOffload, bleFrameOffloadBytes
        case bleFrameOther, bleFrameOtherBytes
        // Live heart rate on the main thread: samples ingested, smoothed values published, LiveState change notices.
        case hrSamples, bpmPublished, liveWillChange
        // SwiftUI body evaluations of the main screens while the app was not active.
        case uiBodyBg
        // Inbound BLE notifications (all, and those on the data characteristic), strap-log lines and their main-thread ms.
        case bleFrames, bleRawFrames, logLines, logAppendMs
        // Main-thread CPU (exclusive, ms) and calls of the offload chunk callbacks (`Backfiller`: onBankedOffload, the reject
        // archive sink, ackTrim, onChunk) and of the live-HR banner (`LiveActivityController`: the refresh and the
        // `Activity.activities` listing), plus the banner updates pushed to iOS.
        case mainChunkBankedMs, mainChunkRejectSinkMs, mainChunkAckMs, mainChunkOnChunkMs
        case mainLiveActivityMs, mainLiveActivityListMs
        case chunkBankedCalls, chunkRejectCalls, chunkAckCalls, chunkOnChunkCalls
        case liveActivityCalls, liveActivityListCalls, laPush
        // Run-loop iterations over 100 ms (`ForkRunLoopMeter`), by the condition that held when they ended: total CPU ms, how
        // many ran no `ForkMainCPU` call site at all, and per condition the count and CPU ms (an iteration counts under every
        // condition that held). Then the same by selected tab (CPU ms; `None` = unknown).
        case rlSlowMs, rlSlowNoPoint
        case rlSlowBg, rlSlowBgMs, rlSlowLocked, rlSlowLockedMs, rlSlowCharging, rlSlowChargingMs
        case rlSlowLowPower, rlSlowLowPowerMs, rlSlowOffload, rlSlowOffloadMs, rlSlowLiveActivity, rlSlowLiveActivityMs
        case rlSlowRefresh, rlSlowRefreshMs, rlSlowWifi, rlSlowWifiMs, rlSlowCellular, rlSlowCellularMs
        case rlSlowTab0, rlSlowTab1, rlSlowTab2, rlSlowTab3, rlSlowTab4, rlSlowTabNone
        // Exposure: one tick per ~10 s flush, booked under the conditions that held at that moment, so a condition's share of
        // the time is `rlExp<Cond> / rlExpTicks` (the denominator for the slow-iteration counters above).
        case rlExpTicks, rlExpBg, rlExpLocked, rlExpCharging, rlExpLowPower, rlExpOffload, rlExpLiveActivity
        case rlExpRefresh, rlExpWifi, rlExpCellular
        case rlExpTab0, rlExpTab1, rlExpTab2, rlExpTab3, rlExpTab4, rlExpTabNone
        // The main-thread stack sampler's own cost (`ForkMainStackSampler`): suspending samples taken, ticks classified as
        // waiting (no suspension), microseconds the main thread stayed suspended, ms spent resolving names and aggregating,
        // the watchdog thread's own CPU ms, ms writing the aggregates, samples dropped (hourly cap, unprimed tick, failed
        // read), walks cut at 24 frames, dictionary keys refused, frames resolved and how many had no symbol name.
        case stackSamples, stackWaitSamples, stackSampleUs, stackProcessMs, stackWatchdogMs, stackWriteMs
        case stackDropped, stackWalkTruncated, stackKeyOverflow, stackFrames, stackFramesNoSymbol
        // The counters' own bookkeeping: disk writes of the hour buckets, their ms (and the part on the main thread), bytes
        // written, and `note` calls made on the main thread.
        case countersFlushes, countersFlushMs, countersFlushMainMs, countersFlushBytes, countersNoteMain
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
        /// This thread's port is the one captured on the main thread. false until it is captured.
        var isRealMain: Bool = false
    }

    // The main thread, captured once on the main thread itself (`mach_thread_self`, kept for the process lifetime).
    // Written and read under `lock` only (`note`), so no further synchronisation is needed.
    private static var mainPort: mach_port_t = 0
    private static var mainThreadCaptured: Bool { mainPort != 0 }

    /// The captured main-thread port, nil before `captureMainThreadIfNeeded` ran on the main thread. Read it on the main thread.
    static func mainThreadPort() -> mach_port_t? { mainPort == 0 ? nil : mainPort }

    /// Remember the main thread's port. A no-op off the main thread or once captured.
    static func captureMainThreadIfNeeded() {
        guard mainPort == 0, pthread_main_np() != 0 else { return }
        mainPort = mach_thread_self()
    }

    /// What one sample says about the "first thread is main" assumption: `.mainThreadUnknown` before the capture,
    /// `.mainThreadMismatch` when the first listed thread is not the captured main thread, nil when they agree.
    static func mainCheck(slices: [ThreadSlice], captured: Bool) -> Counter? {
        guard captured else { return .mainThreadUnknown }
        guard let first = slices.first else { return nil }
        return first.isRealMain ? nil : .mainThreadMismatch
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
            if slice.isRealMain { byBucket[.cpuThrMainRealMs, default: 0] += delta }
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
                                   cpuMs: ms(basic.user_time) + ms(basic.system_time), isMain: index == 0,
                                   isRealMain: mainThreadCaptured && thread == mainPort))
        }
        return out
    }

    /// CPU (user + system) of the captured MAIN thread so far, microseconds; 0 before it is captured. Callable from any
    /// thread: a `thread_info` read of the main port, so it stays valid across the awaits a phase spans.
    static func mainThreadCPUMicros() -> Int {
        guard mainPort != 0 else { return 0 }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        func us(_ t: time_value_t) -> Int { Int(t.seconds) * 1_000_000 + Int(t.microseconds) }
        return us(info.user_time) + us(info.system_time)
    }

    /// CPU time of the calling thread so far, nanoseconds (0 when the clock is unavailable).
    static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    /// Process-CPU laps through the day loop of a re-score pass: every `lap()` returns the CPU since the previous one,
    /// and the caller books it to the bucket that just ended.
    struct RescorePhaseTally {
        var keyMs = 0, prepMs = 0, scoreMs = 0, scoreThreadUs = 0, restMs = 0, paceMs = 0
        /// Main-thread CPU (µs) during the key and prep laps, booked by the caller from `lastMainUs`.
        var keyMainUs = 0, prepMainUs = 0
        /// The main thread's CPU (µs) since the previous lap, as of the last `lap()`.
        private(set) var lastMainUs = 0
        private var mark = ForkEnergyCounters.cpuNowMillis()
        private var mainMark = ForkEnergyCounters.mainThreadCPUMicros()
        mutating func lap() -> Int {
            let now = ForkEnergyCounters.cpuNowMillis()
            let mainNow = ForkEnergyCounters.mainThreadCPUMicros()
            defer { mark = now; mainMark = mainNow }
            lastMainUs = max(0, mainNow - mainMark)
            return max(0, now - mark)
        }
    }

    /// Book a finished re-score pass's phases (the loop's, plus the part before it).
    func noteRescorePhases(preMs: Int, _ tally: RescorePhaseTally, at now: Date = Date()) {
        note(.rescorePreMs, by: preMs, at: now)
        note(.rescoreKeyMs, by: tally.keyMs, at: now)
        note(.rescorePrepMs, by: tally.prepMs, at: now)
        note(.rescoreKeyMainMs, by: tally.keyMainUs / 1000, at: now)
        note(.rescorePrepMainMs, by: tally.prepMainUs / 1000, at: now)
        note(.rescoreScoreMs, by: tally.scoreMs, at: now)
        note(.rescoreScoreThrMs, by: tally.scoreThreadUs / 1000, at: now)
        note(.rescoreLoopRestMs, by: tally.restMs, at: now)
        note(.rescorePaceMs, by: tally.paceMs, at: now)
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
    // The counters' own cost, booked into the current hour after each disk write (lock held).
    private var noteMainPending = 0
    private var flushRemainderUs = 0, flushMainRemainderUs = 0
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
        Self.captureMainThreadIfNeeded()
        if pthread_main_np() != 0 { noteMainPending += 1 }
        if counter == .liveWillChange { ForkRunLoopMeter.noteWillChange() }
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
                if let check = Self.mainCheck(slices: slices, captured: Self.mainThreadCaptured) {
                    hours[key, default: [:]][check.rawValue, default: 0] += 1
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
            if let split = Self.mainSplitLine(perDay[day] ?? [:]) { lines.append("\(day) " + split) }
            if let check = Self.mainCheckLine(perDay[day] ?? [:]) { lines.append("\(day) " + check) }
            lines.append(contentsOf: ForkRunLoopMeter.reportLines(day: day, counts: perDay[day] ?? [:]))
            lines.append(contentsOf: ForkMainStackSampler.reportLines(day: day, counts: perDay[day] ?? [:]))
        }
        lines.append(contentsOf: ForkMainStackSampler.last24Lines())
        lines.append("— last \(lastHours) h —")
        for hour in data.keys.sorted().suffix(lastHours) {
            lines.append("\(hour)h: " + Self.format(data[hour] ?? [:]))
            if let split = Self.mainSplitLine(data[hour] ?? [:]) { lines.append("\(hour)h " + split) }
        }
        return lines.joined(separator: "\n")
    }

    /// The counters that book main-thread call sites (`ForkMainCPU`), in the order the split line names them.
    private static let mainPoints: [(label: String, counter: Counter)] =
        ForkMainCPU.Point.allCases.map { ($0.label, $0.counter) }

    /// "main split: main=… attributed=… (notify=… …) unattributed=… (n%)": the sampled main-thread CPU, what the call sites
    /// explain, and the rest. nil when nothing was sampled or no call site booked anything. The two come from different
    /// clocks (a 5-minute thread sample and the call sites' own flushes), so a single hour can be off at its edges; read days.
    static func mainSplitLine(_ counts: [String: Int]) -> String? {
        let main = counts[Counter.cpuThrMainMs.rawValue] ?? 0
        let parts = mainPoints.map { ($0.label, counts[$0.counter.rawValue] ?? 0) }
        let attributed = parts.reduce(0) { $0 + $1.1 }
        guard main > 0, attributed > 0 else { return nil }
        let rest = max(0, main - attributed)
        let share = Int((Double(rest) / Double(main) * 100).rounded())
        let named = parts.filter { $0.1 > 0 }.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        return "main split: main=\(main)ms attributed=\(attributed)ms (\(named)) unattributed=\(rest)ms (\(share)%)"
    }

    /// "main check: first=… real=… mismatch=… unknown=…": the CPU booked to the first listed thread against the captured
    /// main thread, and how many samples disagreed. nil when neither was sampled. When `real` differs from `first`
    /// the premise of the main split changes, and the figure to trust is `real`.
    static func mainCheckLine(_ counts: [String: Int]) -> String? {
        let first = counts[Counter.cpuThrMainMs.rawValue] ?? 0
        let real = counts[Counter.cpuThrMainRealMs.rawValue] ?? 0
        let mismatch = counts[Counter.mainThreadMismatch.rawValue] ?? 0
        let unknown = counts[Counter.mainThreadUnknown.rawValue] ?? 0
        guard first > 0 || real > 0 else { return nil }
        return "main check: first=\(first)ms real=\(real)ms mismatch=\(mismatch) unknown=\(unknown)"
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
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let data = try? JSONEncoder().encode(hours) else { return }
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
        lastFlush = now
        // fork-perf: TEMP — what this write cost, booked into the current hour (so the next write carries it).
        let micros = Int((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started) / 1000)
        let key = Self.bucket(for: now, timeZone: timeZone)
        func book(_ c: Counter, _ n: Int) { if n > 0 { hours[key, default: [:]][c.rawValue, default: 0] += n } }
        flushRemainderUs += micros
        book(.countersFlushMs, flushRemainderUs / 1000); flushRemainderUs %= 1000
        if pthread_main_np() != 0 {
            flushMainRemainderUs += micros
            book(.countersFlushMainMs, flushMainRemainderUs / 1000); flushMainRemainderUs %= 1000
        }
        book(.countersFlushes, 1); book(.countersFlushBytes, data.count); book(.countersNoteMain, noteMainPending)
        noteMainPending = 0
        dirty = true
    }
}
