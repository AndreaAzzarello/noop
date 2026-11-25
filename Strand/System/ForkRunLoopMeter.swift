import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// fork-perf: TEMP — main run-loop iterations. Remove with `git revert` of the "perf(temp): main run-loop iterations" commit.

/// What the main thread spends per run-loop iteration, to explain the CPU that no call site of `ForkMainCPU` covers.
///
/// An iteration runs from the main run loop waking up to it going back to sleep, so it includes everything that ran
/// in between: BLE callbacks, timers, Combine sinks and the SwiftUI / Core Animation commit that happens in the
/// run loop's own `beforeWaiting` observers, which no call site wraps. Per iteration it measures thread CPU and
/// wall time, and books, per hour: how many iterations (foreground and background), how many fell in each CPU
/// band (<1, 1-10, 10-100, >100 ms), the total CPU and the part of it in iterations a BLE call site touched, the
/// `LiveState` change notices, and the five slowest iterations of each day.
///
/// Nothing is allocated, locked or written inside the observer callbacks: they do arithmetic on preallocated
/// fields, and counters are handed to `ForkEnergyCounters` in batches every 10 s from the main thread, like
/// `ForkMainCPU`. Counts and milliseconds only. Off with the UserDefaults key `fork.runloopMeter.off`.
enum ForkRunLoopMeter {

    static let disableKey = "fork.runloopMeter.off"
    static let slowestKept = 5
    static let flushIntervalNanos: UInt64 = 10 * 1_000_000_000

    /// CPU bands of one iteration, in nanoseconds: <1 ms, 1-10 ms, 10-100 ms, >100 ms.
    static func band(cpuNs: UInt64) -> Int {
        switch cpuNs {
        case ..<1_000_000: return 0
        case ..<10_000_000: return 1
        case ..<100_000_000: return 2
        default: return 3
        }
    }

    struct Slow: Equatable {
        var cpuNs: UInt64 = 0
        var wallNs: UInt64 = 0
        var hour: Int = 0
        var willChange: Int = 0
        var ble: Bool = false
    }

    /// Pure accounting: the clocks and the context are passed in, so the arithmetic runs in a test.
    struct Core {
        private(set) var iterFg = 0, iterBg = 0
        private(set) var bands = [Int](repeating: 0, count: 4)
        private(set) var cpuNs: UInt64 = 0, cpuBleNs: UInt64 = 0, cpuBgNs: UInt64 = 0
        private(set) var willChange = 0
        private(set) var slowest = [Slow](repeating: Slow(), count: ForkRunLoopMeter.slowestKept)

        /// One finished iteration.
        mutating func record(cpuNs cpu: UInt64, wallNs wall: UInt64, willChange changes: Int, ble: Bool,
                             background: Bool, hour: Int) {
            if background { iterBg += 1; cpuBgNs &+= cpu } else { iterFg += 1 }
            bands[ForkRunLoopMeter.band(cpuNs: cpu)] += 1
            cpuNs &+= cpu
            if ble { cpuBleNs &+= cpu }
            willChange += changes
            // Keep the five slowest: replace the smallest when this one is slower. In place, no allocation.
            var minIndex = 0
            for i in 1..<slowest.count where slowest[i].cpuNs < slowest[minIndex].cpuNs { minIndex = i }
            if cpu > slowest[minIndex].cpuNs {
                slowest[minIndex] = Slow(cpuNs: cpu, wallNs: wall, hour: hour, willChange: changes, ble: ble)
            }
        }

        var isEmpty: Bool { iterFg + iterBg == 0 }

        /// The batch since the last drain as whole counters; the sub-millisecond CPU remainders carry to the next one.
        mutating func drain() -> (counters: [(ForkEnergyCounters.Counter, Int)], slowest: [Slow]) {
            var out: [(ForkEnergyCounters.Counter, Int)] = []
            func add(_ c: ForkEnergyCounters.Counter, _ n: Int) { if n > 0 { out.append((c, n)) } }
            add(.rlIterFg, iterFg); add(.rlIterBg, iterBg)
            add(.rlBandLt1, bands[0]); add(.rlBand1to10, bands[1])
            add(.rlBand10to100, bands[2]); add(.rlBandGt100, bands[3])
            add(.rlWillChange, willChange)
            let cpuMs = Int(cpuNs / 1_000_000), bleMs = Int(cpuBleNs / 1_000_000), bgMs = Int(cpuBgNs / 1_000_000)
            add(.rlCpuMs, cpuMs); add(.rlCpuBleMs, bleMs); add(.rlCpuBgMs, bgMs)
            let kept = slowest.filter { $0.cpuNs > 0 }
            iterFg = 0; iterBg = 0; willChange = 0
            for i in bands.indices { bands[i] = 0 }
            cpuNs %= 1_000_000; cpuBleNs %= 1_000_000; cpuBgNs %= 1_000_000
            for i in slowest.indices { slowest[i] = Slow() }
            return (out, kept)
        }
    }

    // MARK: Slowest per day (persisted beside the counters, merged at flush)

    /// The `slowestKept` slowest of `existing` + `new`, slowest first.
    static func mergeSlowest(_ existing: [Slow], _ new: [Slow]) -> [Slow] {
        Array((existing + new).sorted { $0.cpuNs > $1.cpuNs }.prefix(slowestKept))
    }

    struct SlowRecord: Codable, Equatable {
        let cpuMs: Int, wallMs: Int, hour: Int, willChange: Int, ble: Bool
    }

    /// "runloop slowest: 1) cpu=…ms wall=…ms hour=… willChange=… ble=yes …": nil when the day has none.
    static func slowestLine(_ records: [SlowRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let items = records.enumerated().map { i, r in
            "\(i + 1)) cpu=\(r.cpuMs)ms wall=\(r.wallMs)ms hour=\(r.hour) willChange=\(r.willChange) ble=\(r.ble ? "yes" : "no")"
        }
        return "runloop slowest: " + items.joined(separator: " ")
    }

    /// "runloop: iter fg=… bg=… cpu=…ms (ble=…ms bg=…ms) bands <1=… 1-10=… 10-100=… >100=… willChange=…": nil with no iterations.
    static func summaryLine(_ counts: [String: Int]) -> String? {
        func v(_ c: ForkEnergyCounters.Counter) -> Int { counts[c.rawValue] ?? 0 }
        guard v(.rlIterFg) + v(.rlIterBg) > 0 else { return nil }
        return "runloop: iter fg=\(v(.rlIterFg)) bg=\(v(.rlIterBg)) cpu=\(v(.rlCpuMs))ms (ble=\(v(.rlCpuBleMs))ms bg=\(v(.rlCpuBgMs))ms) "
            + "bands <1=\(v(.rlBandLt1)) 1-10=\(v(.rlBand1to10)) 10-100=\(v(.rlBand10to100)) >100=\(v(.rlBandGt100)) "
            + "willChange=\(v(.rlWillChange))"
    }

    // MARK: Facade (main thread only)

    private static var core = Core()
    private static var installed = false
    private static var startCPU: UInt64 = 0
    private static var startWall: UInt64 = 0
    private static var started = false
    private static var lastFlush: UInt64 = 0
    private static var changesAtStart = 0
    private static var changes = 0
    private static var slowestByDay: [String: [SlowRecord]] = [:]
    private static var slowestLoaded = false
    private static var slowestDirty = false

    /// Set by `ForkMainCPU.begin` (a BLE call site ran in this iteration).
    static var touched = false

    /// A `LiveState` change notice (called from `ForkEnergyCounters.note(.liveWillChange)` on the main thread).
    static func noteWillChange() { if pthread_main_np() != 0 { changes += 1 } }

    private static var isBackground: Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }

    /// Install on the main run loop. Call once, on the main thread. No-op when switched off.
    static func install() {
        guard !installed, pthread_main_np() != 0,
              !UserDefaults.standard.bool(forKey: disableKey) else { return }
        installed = true
        let runLoop = CFRunLoopGetMain()
        let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            startCPU = ForkEnergyCounters.threadCPUNanos()
            startWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            changesAtStart = changes
            touched = false
            started = true
        }
        // Last in the sleep sequence, after SwiftUI's and Core Animation's own `beforeWaiting` commits.
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard started else { return }
            started = false
            let cpu = ForkEnergyCounters.threadCPUNanos() &- startCPU
            let nowWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            core.record(cpuNs: cpu, wallNs: nowWall &- startWall, willChange: changes - changesAtStart, ble: touched,
                        background: isBackground, hour: Calendar.current.component(.hour, from: Date()))
            if nowWall &- lastFlush >= flushIntervalNanos { flush(nowWall) }
        }
        CFRunLoopAddObserver(runLoop, begin, .commonModes)
        CFRunLoopAddObserver(runLoop, end, .commonModes)
    }

    private static func flush(_ nowWall: UInt64) {
        lastFlush = nowWall
        guard !core.isEmpty else { return }
        let batch = core.drain()
        for (counter, n) in batch.counters { ForkEnergyCounters.shared.note(counter, by: n) }
        bookSlowest(batch.slowest)
    }

    // MARK: Persistence of the slowest five (a small file beside the counters)

    private static var fileURL: URL? {
        ForkEnergyCounters.defaultFileURL()?.deletingLastPathComponent().appendingPathComponent("runloop-slowest.json")
    }

    private static func loadSlowestIfNeeded() {
        guard !slowestLoaded else { return }
        slowestLoaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [SlowRecord]].self, from: data) else { return }
        slowestByDay = decoded
    }

    private static func bookSlowest(_ batch: [Slow]) {
        guard !batch.isEmpty else { return }
        loadSlowestIfNeeded()
        let day = String(ForkEnergyCounters.bucket(for: Date(), timeZone: .current).prefix(10))
        let existing = (slowestByDay[day] ?? []).map {
            Slow(cpuNs: UInt64($0.cpuMs) * 1_000_000, wallNs: UInt64($0.wallMs) * 1_000_000, hour: $0.hour,
                 willChange: $0.willChange, ble: $0.ble)
        }
        let merged = mergeSlowest(existing, batch).map {
            SlowRecord(cpuMs: Int($0.cpuNs / 1_000_000), wallMs: Int($0.wallNs / 1_000_000), hour: $0.hour,
                       willChange: $0.willChange, ble: $0.ble)
        }
        guard merged != slowestByDay[day] else { return }
        slowestByDay[day] = merged
        for old in slowestByDay.keys.sorted().dropLast(7) { slowestByDay[old] = nil }
        guard let url = fileURL, let data = try? JSONEncoder().encode(slowestByDay) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The per-day report lines for `day` ("yyyy-MM-dd"): summary from the day's counters, then the slowest five.
    static func reportLines(day: String, counts: [String: Int]) -> [String] {
        // The slowest-five store belongs to the main thread; a report built elsewhere carries the summary only.
        let onMain = pthread_main_np() != 0
        if onMain { loadSlowestIfNeeded() }
        return [summaryLine(counts), onMain ? slowestLine(slowestByDay[day] ?? []) : nil]
            .compactMap { $0 }.map { "\(day) " + $0 }
    }
}
