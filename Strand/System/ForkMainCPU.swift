import Foundation
import WhoopProtocol

// fork-perf: TEMP — main-thread CPU by call site and inbound BLE frames by class. Remove with `git revert` of the
// "perf(temp): main-thread CPU by call site" commit.

/// Where the main thread's CPU goes, one figure per call site, in thread-CPU milliseconds per hour.
///
/// Each call site wraps a SYNCHRONOUS stretch of code in `begin` / `end`. Points nest (a BLE notification calls the router,
/// the router publishes, a sink runs), so a point books its EXCLUSIVE time: its own elapsed thread CPU minus that of the
/// points it called. The figures therefore add up without double counting, and `cpuThrMainMs` (the sampled main thread)
/// minus their sum is what no point explains.
///
/// Rules for a call site: never keep a point open across an `await` (the thread would be running other work), and place
/// `end` where no early exit can skip it (a `defer` or straight-line code). `end` is idempotent and closes any point left
/// open inside it, so a missed `end` of an inner point cannot outlive the outer one.
///
/// Counts and milliseconds only. Main thread only: any other thread gets a no-op token.
enum ForkMainCPU {

    enum Point: Int, CaseIterable {
        /// The whole BLE `didUpdateValueFor` handler (its own part: reassembly, verify, probes, the offload queueing).
        case bleNotify
        /// `FrameRouter.handle` for a live frame.
        case bleRouter
        /// The standard heart-rate profile parse and what it publishes, minus the points below.
        case bleStdHR
        /// `Collector.ingest` and `Collector.ingestStandardHR`.
        case bleCollector
        /// The Smart Wake heart-rate hook (`SmartWakeLiveWiring`), called per standard-HR sample on a 5/MG.
        case bleSmartWake
        /// `AppModel.ingestHR`: smoothing, workout sampling and the stress evaluation.
        case ingestHR
        /// `LiveState.append(log:)`.
        case log
        /// The synchronous parts of the history offload on the main actor (frame classification, chunk post-processing).
        case offload
        /// Combine sinks that run outside the points above.
        case sinks

        var counter: ForkEnergyCounters.Counter {
            switch self {
            case .bleNotify: return .mainBleNotifyMs
            case .bleRouter: return .mainBleRouterMs
            case .bleStdHR: return .mainBleStdHRMs
            case .bleCollector: return .mainBleCollectorMs
            case .bleSmartWake: return .mainBleSmartWakeMs
            case .ingestHR: return .mainIngestHRMs
            case .log: return .mainLogMs
            case .offload: return .mainOffloadMs
            case .sinks: return .mainSinksMs
            }
        }
    }

    /// Pure stack accounting (the clock is passed in, so the arithmetic runs in a test).
    struct Meter {
        private var stack: [(serial: Int, point: Point, start: UInt64, child: UInt64)] = []
        private var exclusiveNs = [UInt64](repeating: 0, count: Point.allCases.count)
        private var nextSerial = 0

        var isIdle: Bool { stack.isEmpty }

        /// - Returns: the token `end` takes: a serial number, never reused, so a late `end` cannot close another point.
        mutating func begin(_ point: Point, at now: UInt64) -> Int {
            let serial = nextSerial
            nextSerial += 1
            stack.append((serial, point, now, 0))
            return serial
        }

        /// Closes the point with this token and every point still open above it. A no-op once it is already closed.
        mutating func end(_ token: Int, at now: UInt64) {
            guard let index = stack.lastIndex(where: { $0.serial == token }) else { return }
            while stack.count > index { pop(at: now) }
        }

        private mutating func pop(at now: UInt64) {
            let top = stack.removeLast()
            let inclusive = now &- top.start
            exclusiveNs[top.point.rawValue] &+= inclusive &- min(top.child, inclusive)
            if !stack.isEmpty { stack[stack.count - 1].child &+= inclusive }
        }

        /// Whole milliseconds per point since the last drain; the sub-millisecond remainder carries to the next one.
        mutating func drainMillis() -> [(point: Point, ms: Int)] {
            var out: [(point: Point, ms: Int)] = []
            for point in Point.allCases {
                let ms = Int(exclusiveNs[point.rawValue] / 1_000_000)
                guard ms > 0 else { continue }
                exclusiveNs[point.rawValue] %= 1_000_000
                out.append((point, ms))
            }
            return out
        }
    }

    // MARK: Inbound frames by class

    enum FrameClass: Int, CaseIterable {
        case stdHR, raw43, realtime40, offload, other

        /// The packet type sits at the inner-record start: frame[4] on a WHOOP 4.0, frame[8] on a 5/MG (puffin envelope).
        /// Types 47/48/49/50/56 are the history offload (the set `BLEManager.isOffloadFrame` uses).
        static func classify(frame: [UInt8], family: DeviceFamily) -> FrameClass {
            let typeIndex = family == .whoop5 ? 8 : 4
            guard frame.count > typeIndex else { return .other }
            switch frame[typeIndex] {
            case 43: return .raw43
            case 40: return .realtime40
            case 47, 48, 49, 50, 56: return .offload
            default: return .other
            }
        }

        var counters: (count: ForkEnergyCounters.Counter, bytes: ForkEnergyCounters.Counter) {
            switch self {
            case .stdHR: return (.bleFrameStdHR, .bleFrameStdHRBytes)
            case .raw43: return (.bleFrameRaw43, .bleFrameRaw43Bytes)
            case .realtime40: return (.bleFrameRealtime40, .bleFrameRealtime40Bytes)
            case .offload: return (.bleFrameOffload, .bleFrameOffloadBytes)
            case .other: return (.bleFrameOther, .bleFrameOtherBytes)
            }
        }
    }

    // MARK: Facade (main thread only)

    private static var meter = Meter()
    private static var pendingFrames = [Int](repeating: 0, count: FrameClass.allCases.count)
    private static var pendingBytes = [Int](repeating: 0, count: FrameClass.allCases.count)
    private static var lastFlushNanos: UInt64 = 0
    /// Counters are written to the hour buckets at most this often; the work in between is a few additions.
    static let flushIntervalNanos: UInt64 = 10 * 1_000_000_000

    private static var onMain: Bool { pthread_main_np() != 0 }

    /// Opens a point. Returns -1 off the main thread, which `end` ignores.
    static func begin(_ point: Point) -> Int {
        guard onMain else { return -1 }
        ForkRunLoopMeter.touched = true // fork-perf: TEMP (this run-loop iteration ran a BLE call site)
        return meter.begin(point, at: ForkEnergyCounters.threadCPUNanos())
    }

    static func end(_ token: Int) {
        guard token >= 0, onMain else { return }
        meter.end(token, at: ForkEnergyCounters.threadCPUNanos())
        if meter.isIdle { flushIfDue() }
    }

    /// One complete frame of the data / command / event characteristics (bytes of the complete frame).
    static func noteFrame(_ frame: [UInt8], family: DeviceFamily) {
        note(FrameClass.classify(frame: frame, family: family), bytes: frame.count)
    }

    /// One notification of the standard heart-rate characteristic.
    static func noteStdHR(bytes: Int) { note(.stdHR, bytes: bytes) }

    private static func note(_ cls: FrameClass, bytes: Int) {
        guard onMain else {
            let c = cls.counters
            ForkEnergyCounters.shared.note(c.count)
            ForkEnergyCounters.shared.note(c.bytes, by: bytes)
            return
        }
        pendingFrames[cls.rawValue] += 1
        pendingBytes[cls.rawValue] += bytes
        if meter.isIdle { flushIfDue() }
    }

    private static func flushIfDue() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- lastFlushNanos >= flushIntervalNanos else { return }
        lastFlushNanos = now
        for item in meter.drainMillis() { ForkEnergyCounters.shared.note(item.point.counter, by: item.ms) }
        for cls in FrameClass.allCases where pendingFrames[cls.rawValue] > 0 {
            let c = cls.counters
            ForkEnergyCounters.shared.note(c.count, by: pendingFrames[cls.rawValue])
            ForkEnergyCounters.shared.note(c.bytes, by: pendingBytes[cls.rawValue])
            pendingFrames[cls.rawValue] = 0
            pendingBytes[cls.rawValue] = 0
        }
    }
}
