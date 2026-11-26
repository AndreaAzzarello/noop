import Foundation
import Network
import os
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
/// An iteration over 100 ms is also labelled with the conditions that held when it ended (`CondKind`: background, screen
/// locked, phone charging, Low Power Mode, offload frames flowing, live-HR banner up, offload refresh running, Wi-Fi,
/// cellular), the selected tab and which `ForkMainCPU` call sites ran in it. The conditions are read ONLY for those
/// iterations, plus once per flush as an "exposure" tick that gives each condition's share of the time. Each slow
/// iteration is also a Points of Interest signpost event, so Instruments can jump to it.
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
        /// `CondKind` bits that held, `ForkMainCPU.Point` bits that ran, selected tab (-1 unknown).
        var cond: UInt16 = 0
        var ran: UInt32 = 0
        var tab: Int = -1
    }

    /// The conditions an iteration over 100 ms is labelled with. The raw value is the bit index.
    enum CondKind: Int, CaseIterable {
        case bg, locked, charging, lowPower, offload, liveActivity, refresh, wifi, cellular

        var bit: UInt16 { 1 << UInt16(rawValue) }

        var label: String {
            switch self {
            case .bg: return "bg"
            case .locked: return "locked"
            case .charging: return "charging"
            case .lowPower: return "lowPower"
            case .offload: return "offload"
            case .liveActivity: return "liveActivity"
            case .refresh: return "refresh"
            case .wifi: return "wifi"
            case .cellular: return "cellular"
            }
        }

        /// Slow iterations under this condition: count and CPU ms.
        var slow: (count: ForkEnergyCounters.Counter, ms: ForkEnergyCounters.Counter) {
            switch self {
            case .bg: return (.rlSlowBg, .rlSlowBgMs)
            case .locked: return (.rlSlowLocked, .rlSlowLockedMs)
            case .charging: return (.rlSlowCharging, .rlSlowChargingMs)
            case .lowPower: return (.rlSlowLowPower, .rlSlowLowPowerMs)
            case .offload: return (.rlSlowOffload, .rlSlowOffloadMs)
            case .liveActivity: return (.rlSlowLiveActivity, .rlSlowLiveActivityMs)
            case .refresh: return (.rlSlowRefresh, .rlSlowRefreshMs)
            case .wifi: return (.rlSlowWifi, .rlSlowWifiMs)
            case .cellular: return (.rlSlowCellular, .rlSlowCellularMs)
            }
        }

        var exposure: ForkEnergyCounters.Counter {
            switch self {
            case .bg: return .rlExpBg
            case .locked: return .rlExpLocked
            case .charging: return .rlExpCharging
            case .lowPower: return .rlExpLowPower
            case .offload: return .rlExpOffload
            case .liveActivity: return .rlExpLiveActivity
            case .refresh: return .rlExpRefresh
            case .wifi: return .rlExpWifi
            case .cellular: return .rlExpCellular
            }
        }
    }

    /// Tabs 0-4 and "unknown" (index 5).
    static let slowTabCounters: [ForkEnergyCounters.Counter] =
        [.rlSlowTab0, .rlSlowTab1, .rlSlowTab2, .rlSlowTab3, .rlSlowTab4, .rlSlowTabNone]
    static let exposureTabCounters: [ForkEnergyCounters.Counter] =
        [.rlExpTab0, .rlExpTab1, .rlExpTab2, .rlExpTab3, .rlExpTab4, .rlExpTabNone]
    static func tabIndex(_ tab: Int) -> Int { (0...4).contains(tab) ? tab : 5 }
    static let slowThresholdNs: UInt64 = 100_000_000

    /// "bg,locked": the names of the condition bits set, "none" when there are none.
    static func condLabel(_ mask: UInt16) -> String {
        let names = CondKind.allCases.filter { mask & $0.bit != 0 }.map(\.label)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// "stdHR,ingestHR": the call sites whose bit is set, "none" when none ran.
    static func ranLabel(_ mask: UInt32) -> String {
        let names = ForkMainCPU.Point.allCases.filter { mask & (1 << UInt32($0.rawValue)) != 0 }.map(\.label)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// Pure accounting: the clocks and the context are passed in, so the arithmetic runs in a test.
    struct Core {
        private(set) var iterFg = 0, iterBg = 0
        private(set) var bands = [Int](repeating: 0, count: 4)
        private(set) var cpuNs: UInt64 = 0, cpuBleNs: UInt64 = 0, cpuBgNs: UInt64 = 0
        private(set) var willChange = 0
        private(set) var slowest = [Slow](repeating: Slow(), count: ForkRunLoopMeter.slowestKept)
        // Iterations over 100 ms by condition and tab, and the exposure ticks (see the header).
        private var slowNs: UInt64 = 0, slowNoPoint = 0
        private var slowCondCount = [Int](repeating: 0, count: CondKind.allCases.count)
        private var slowCondNs = [UInt64](repeating: 0, count: CondKind.allCases.count)
        private var slowTabNs = [UInt64](repeating: 0, count: 6)
        private var expTicks = 0
        private var expCond = [Int](repeating: 0, count: CondKind.allCases.count)
        private var expTab = [Int](repeating: 0, count: 6)

        /// One exposure tick: the conditions and the tab that hold now.
        mutating func expose(conditions: UInt16, tab: Int) {
            expTicks += 1
            for k in CondKind.allCases where conditions & k.bit != 0 { expCond[k.rawValue] += 1 }
            expTab[ForkRunLoopMeter.tabIndex(tab)] += 1
        }

        /// One finished iteration. `conditions` is only meaningful (and only read by the caller) for an iteration over 100 ms.
        mutating func record(cpuNs cpu: UInt64, wallNs wall: UInt64, willChange changes: Int, ble: Bool,
                             background: Bool, hour: Int, conditions: UInt16 = 0, ran: UInt32 = 0, tab: Int = -1) {
            if cpu >= ForkRunLoopMeter.slowThresholdNs {
                slowNs &+= cpu
                if ran == 0 { slowNoPoint += 1 }
                for k in CondKind.allCases where conditions & k.bit != 0 {
                    slowCondCount[k.rawValue] += 1
                    slowCondNs[k.rawValue] &+= cpu
                }
                slowTabNs[ForkRunLoopMeter.tabIndex(tab)] &+= cpu
            }
            if background { iterBg += 1; cpuBgNs &+= cpu } else { iterFg += 1 }
            bands[ForkRunLoopMeter.band(cpuNs: cpu)] += 1
            cpuNs &+= cpu
            if ble { cpuBleNs &+= cpu }
            willChange += changes
            // Keep the five slowest: replace the smallest when this one is slower. In place, no allocation.
            var minIndex = 0
            for i in 1..<slowest.count where slowest[i].cpuNs < slowest[minIndex].cpuNs { minIndex = i }
            if cpu > slowest[minIndex].cpuNs {
                slowest[minIndex] = Slow(cpuNs: cpu, wallNs: wall, hour: hour, willChange: changes, ble: ble,
                                         cond: conditions, ran: ran, tab: tab)
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
            add(.rlSlowMs, Int(slowNs / 1_000_000)); add(.rlSlowNoPoint, slowNoPoint)
            for k in CondKind.allCases {
                add(k.slow.count, slowCondCount[k.rawValue])
                add(k.slow.ms, Int(slowCondNs[k.rawValue] / 1_000_000))
                add(k.exposure, expCond[k.rawValue])
            }
            for i in 0..<6 {
                add(ForkRunLoopMeter.slowTabCounters[i], Int(slowTabNs[i] / 1_000_000))
                add(ForkRunLoopMeter.exposureTabCounters[i], expTab[i])
            }
            add(.rlExpTicks, expTicks)
            slowNs %= 1_000_000; slowNoPoint = 0; expTicks = 0
            for i in slowCondCount.indices { slowCondCount[i] = 0; slowCondNs[i] %= 1_000_000; expCond[i] = 0 }
            for i in 0..<6 { slowTabNs[i] %= 1_000_000; expTab[i] = 0 }
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
        /// Absent in records written before the conditions existed.
        var cond: Int? = nil, ran: Int? = nil, tab: Int? = nil
    }

    /// "runloop slowest: 1) cpu=…ms wall=…ms hour=… willChange=… ble=yes …": nil when the day has none.
    static func slowestLine(_ records: [SlowRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let items = records.enumerated().map { i, r in
            var line = "\(i + 1)) cpu=\(r.cpuMs)ms wall=\(r.wallMs)ms hour=\(r.hour) willChange=\(r.willChange) ble=\(r.ble ? "yes" : "no")"
            if let cond = r.cond {
                line += " cond=\(condLabel(UInt16(truncatingIfNeeded: cond)))"
                line += " ran=\(ranLabel(UInt32(truncatingIfNeeded: r.ran ?? 0)))"
                line += " tab=\(r.tab.map(String.init) ?? "?")"
            }
            return line
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

    /// "runloop slow by condition: cpu=…ms noPoint=… | bg=n/ms … | tab0=ms … | exposure ticks=… bg=… tab0=…": the CPU of the
    /// iterations over 100 ms split by condition (count/ms; one iteration counts under each condition that held) and by tab,
    /// then how many flush ticks each condition and tab held for. nil when nothing was labelled.
    static func slowByConditionLine(_ counts: [String: Int]) -> String? {
        func v(_ c: ForkEnergyCounters.Counter) -> Int { counts[c.rawValue] ?? 0 }
        guard v(.rlSlowMs) > 0 || v(.rlExpTicks) > 0 else { return nil }
        let conds = CondKind.allCases.map { "\($0.label)=\(v($0.slow.count))/\(v($0.slow.ms))" }.joined(separator: " ")
        let tabNames = ["0", "1", "2", "3", "4", "?"]
        let tabs = tabNames.indices.map { "tab\(tabNames[$0])=\(v(slowTabCounters[$0]))" }.joined(separator: " ")
        let expConds = CondKind.allCases.map { "\($0.label)=\(v($0.exposure))" }.joined(separator: " ")
        let expTabs = tabNames.indices.map { "tab\(tabNames[$0])=\(v(exposureTabCounters[$0]))" }.joined(separator: " ")
        return "runloop slow by condition: cpu=\(v(.rlSlowMs))ms noPoint=\(v(.rlSlowNoPoint)) | \(conds) | \(tabs)ms"
            + " | exposure ticks=\(v(.rlExpTicks)) \(expConds) \(expTabs)"
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

    /// Call sites that ran in this iteration (bit = `Point.rawValue`), and when the offload last ran (uptime ns).
    private static var ranMask: UInt32 = 0
    private static var lastOffloadNanos: UInt64 = 0
    /// Offload frames count as flowing for this long after the last one.
    static let offloadWindowNanos: UInt64 = 5 * 1_000_000_000

    static func noteRan(_ point: ForkMainCPU.Point) {
        ranMask |= 1 << UInt32(point.rawValue)
        if point == .offload { lastOffloadNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    /// Condition inputs set by the app layer (main thread): the selected tab, whether the live-HR banner is up, and how
    /// many `refreshAfterCompletedBackfill` runs are in flight.
    private static var currentTab = -1
    static var liveActivityShowing = false
    static var refreshInFlight = 0
    static func noteTab(_ tab: Int) { currentTab = tab }

    /// Wi-Fi / cellular, from a passive path monitor on its own queue.
    private final class NetState: @unchecked Sendable {
        private let lock = NSLock()
        private var wifi = false, cellular = false
        private let monitor = NWPathMonitor()
        func start() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self.cellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
            }
            monitor.start(queue: DispatchQueue(label: "fork.runloopMeter.net", qos: .utility))
        }
        func read() -> (wifi: Bool, cellular: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (wifi, cellular)
        }
    }
    private static let net = NetState()

    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: Bundle.main.bundleIdentifier ?? "noop", category: .pointsOfInterest))
    private static var intervalState: OSSignpostIntervalState?

    /// The `CondKind` bits that hold now. Main thread; only called for slow iterations and once per flush.
    private static func currentConditions(nowWall: UInt64) -> UInt16 {
        var mask: UInt16 = 0
        func set(_ k: CondKind, _ on: Bool) { if on { mask |= k.bit } }
        set(.bg, isBackground)
        #if canImport(UIKit) && !os(watchOS)
        set(.locked, !UIApplication.shared.isProtectedDataAvailable)
        let battery = UIDevice.current.batteryState
        set(.charging, battery == .charging || battery == .full)
        #endif
        set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
        set(.offload, lastOffloadNanos != 0 && nowWall &- lastOffloadNanos < offloadWindowNanos)
        set(.liveActivity, liveActivityShowing)
        set(.refresh, refreshInFlight > 0)
        let n = net.read()
        set(.wifi, n.wifi); set(.cellular, n.cellular)
        return mask
    }

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
        #if canImport(UIKit) && !os(watchOS)
        UIDevice.current.isBatteryMonitoringEnabled = true // only so `batteryState` reads; no effect on BLE
        #endif
        net.start()
        let runLoop = CFRunLoopGetMain()
        let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            startCPU = ForkEnergyCounters.threadCPUNanos()
            startWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            changesAtStart = changes
            touched = false
            ranMask = 0
            started = true
            if signposter.isEnabled { intervalState = signposter.beginInterval("iteration") }
        }
        // Last in the sleep sequence, after SwiftUI's and Core Animation's own `beforeWaiting` commits.
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard started else { return }
            started = false
            let cpu = ForkEnergyCounters.threadCPUNanos() &- startCPU
            let nowWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let state = intervalState { signposter.endInterval("iteration", state); intervalState = nil }
            // Conditions are read only for an iteration over 100 ms; every other one pays no more than before.
            let slow = cpu >= slowThresholdNs
            let cond = slow ? currentConditions(nowWall: nowWall) : 0
            core.record(cpuNs: cpu, wallNs: nowWall &- startWall, willChange: changes - changesAtStart, ble: touched,
                        background: isBackground, hour: Calendar.current.component(.hour, from: Date()),
                        conditions: cond, ran: ranMask, tab: currentTab)
            if slow, signposter.isEnabled {
                signposter.emitEvent("slow iteration",
                                     "cpu=\(cpu / 1_000_000, privacy: .public)ms cond=\(Int(cond), privacy: .public) ran=\(ranMask, privacy: .public) tab=\(currentTab, privacy: .public)")
            }
            if nowWall &- lastFlush >= flushIntervalNanos { flush(nowWall) }
        }
        CFRunLoopAddObserver(runLoop, begin, .commonModes)
        CFRunLoopAddObserver(runLoop, end, .commonModes)
    }

    private static func flush(_ nowWall: UInt64) {
        lastFlush = nowWall
        guard !core.isEmpty else { return }
        core.expose(conditions: currentConditions(nowWall: nowWall), tab: currentTab)
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
                 willChange: $0.willChange, ble: $0.ble, cond: UInt16(truncatingIfNeeded: $0.cond ?? 0),
                 ran: UInt32(truncatingIfNeeded: $0.ran ?? 0), tab: $0.tab ?? -1)
        }
        let merged = mergeSlowest(existing, batch).map {
            SlowRecord(cpuMs: Int($0.cpuNs / 1_000_000), wallMs: Int($0.wallNs / 1_000_000), hour: $0.hour,
                       willChange: $0.willChange, ble: $0.ble, cond: Int($0.cond), ran: Int($0.ran),
                       tab: $0.tab >= 0 ? $0.tab : nil)
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
        return [summaryLine(counts), slowByConditionLine(counts), onMain ? slowestLine(slowestByDay[day] ?? []) : nil]
            .compactMap { $0 }.map { "\(day) " + $0 }
    }
}
