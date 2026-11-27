import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

// fork-perf: TEMP — main-thread stack sampler for run-loop iterations over 100 ms. Remove with `git revert` of the
// "perf(temp): main-thread stack sampler" commit.

/// Memory the stack walk reads from: the main thread's stack live, a fake one in a test.
protocol ForkStackMemory {
    /// The word at `address`, nil when the 8 bytes are not inside the stack or `address` is not 8-aligned.
    func load(_ address: UInt) -> UInt?
}

/// Says WHAT the main thread runs while a run-loop iteration is slow, which no `ForkMainCPU` call site can.
///
/// A low-priority watchdog thread wakes every 20 ms. While the main run loop is inside an iteration older than 100 ms
/// (`ForkRunLoopMeter` publishes the iteration start in one word), it first reads the main thread's CPU time and
/// classifies the tick: CPU advanced by at least half the tick interval means the main was running (`cpu`), otherwise it
/// was blocked (`wait`). Only a `cpu` tick suspends the main thread, copies PC, LR and FP, walks the frame-pointer chain
/// (at most 24 frames, bounds-checked against the main stack, PAC bits stripped) and resumes it. Between suspend and
/// resume there is no allocation, no lock and no log: only arithmetic on buffers allocated at start. Names are
/// resolved (`dladdr`, `swift_demangle`) and aggregated after the resume.
///
/// Aggregates hold counts and function names only, never health data. Off with the UserDefaults key
/// `fork.stackSampler.off`, or the Test Centre switch.
enum ForkMainStackSampler {

    static let disableKey = "fork.stackSampler.off"
    static let maxFrames = 24
    static let stackKeyFrames = 6
    /// The watchdog's tick, microseconds.
    static let tickMicros: useconds_t = 20_000
    /// A tick starts reading the main thread's CPU from this far into an iteration, so the first sample has a previous reading.
    static let primeNanos: UInt64 = 60_000_000
    /// Suspending samples per hour (the cost-bearing ones). The 20 ms tick already bounds the rate at 50 per second.
    static let samplesPerHourCap = 25_000
    static let persistIntervalNanos: UInt64 = 300 * 1_000_000_000
    static let flushIntervalNanos: UInt64 = 10 * 1_000_000_000

    // MARK: Pure: PAC, classification, stack walk

    /// Return addresses on arm64e carry a pointer signature in the high bits; user addresses fit in 39 bits.
    static func maskPAC(_ address: UInt) -> UInt { address & 0x0000_007F_FFFF_FFFF }

    /// `cpu` when the thread's CPU advanced by at least half the tick interval.
    static func isCPUSample(cpuDeltaMicros: UInt64, intervalMicros: UInt64) -> Bool {
        intervalMicros > 0 && cpuDeltaMicros &* 2 >= intervalMicros
    }

    enum StackWalker {
        /// Frames innermost first: PC, LR, then the return address of every frame record along FP. A record whose return
        /// address equals LR right after it (a leaf that already built its frame) is not repeated. Stops at a null or
        /// misaligned FP, at memory outside the stack, at an FP that does not strictly grow, and at `maxFrames`.
        static func walk<M: ForkStackMemory>(pc: UInt, lr: UInt, fp: UInt, memory: M, maxFrames: Int,
                                         out: UnsafeMutablePointer<UInt>) -> (count: Int, truncated: Bool) {
            guard maxFrames > 0 else { return (0, false) }
            out[0] = ForkMainStackSampler.maskPAC(pc)
            var n = 1
            if lr != 0, maxFrames > 1 { out[1] = ForkMainStackSampler.maskPAC(lr); n = 2 }
            var frame = fp
            var previous: UInt = 0
            var first = true
            while frame != 0, frame & 0xF == 0, frame > previous,
                  let next = memory.load(frame), let rawReturn = memory.load(frame &+ 8) {
                let ret = ForkMainStackSampler.maskPAC(rawReturn)
                if ret == 0 { break }
                if !(first && n == 2 && ret == out[1]) {
                    if n >= maxFrames { return (n, true) }
                    out[n] = ret
                    n += 1
                }
                first = false
                previous = frame
                frame = next
            }
            return (n, false)
        }
    }

    // MARK: Pure: image groups

    enum ImageGroup {
        static let app = "app", bluetooth = "CoreBluetooth", swiftUI = "SwiftUI", dispatch = "libdispatch"
        static let foundation = "Foundation", other = "other"
        static let named = [app, bluetooth, swiftUI, dispatch, foundation, other]

        /// The group of the image at `path` and its basename. `appBundlePath` is the app bundle directory.
        static func classify(path: String, appBundlePath: String) -> (group: String, base: String) {
            let base = path.split(separator: "/").last.map(String.init) ?? path
            if !appBundlePath.isEmpty, path.hasPrefix(appBundlePath) { return (app, base) }
            switch base {
            case "CoreBluetooth": return (bluetooth, base)
            case "SwiftUI", "SwiftUICore", "AttributeGraph": return (swiftUI, base)
            case "Foundation", "CoreFoundation": return (foundation, base)
            default:
                if base.hasPrefix("libdispatch") { return (dispatch, base) }
                return (other, base)
            }
        }
    }

    // MARK: Pure: aggregation

    /// What one hour or one day of samples adds up to. Dictionaries are bounded by `Limits`; a sample that would add a
    /// new key past the bound is counted as overflow instead.
    struct Aggregate: Codable, Equatable {
        var cpu = 0
        var wait = 0
        var stacks: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        var images: [String: Int] = [:]
        var appFrames: [String: Int] = [:]

        struct Limits { var stacks: Int, leaves: Int, appFrames: Int, images: Int }
        static let hourLimits = Limits(stacks: 120, leaves: 100, appFrames: 100, images: 40)
        static let dayLimits = Limits(stacks: 300, leaves: 200, appFrames: 200, images: 60)

        struct Sample {
            /// Innermost first, already shortened.
            var frames: [String]
            var imageGroup: String
            /// "other:<basename>" detail key when the leaf is in an image outside the named groups.
            var imageDetail: String?
            var appFrame: String
        }

        private static func bump(_ dict: inout [String: Int], _ key: String, limit: Int) -> Bool {
            if dict[key] != nil || dict.count < limit { dict[key, default: 0] += 1; return true }
            return false
        }

        /// - Returns: how many of the sample's keys were refused for lack of room.
        @discardableResult
        mutating func addCPU(_ s: Sample, limits: Limits) -> Int {
            cpu += 1
            var overflow = 0
            let key = s.frames.prefix(ForkMainStackSampler.stackKeyFrames).joined(separator: " < ")
            if !Self.bump(&stacks, key, limit: limits.stacks) { overflow += 1 }
            if let leaf = s.frames.first, !Self.bump(&leaves, leaf, limit: limits.leaves) { overflow += 1 }
            if !Self.bump(&images, s.imageGroup, limit: limits.images) { overflow += 1 }
            if let detail = s.imageDetail, !Self.bump(&images, detail, limit: limits.images) { overflow += 1 }
            if !Self.bump(&appFrames, s.appFrame, limit: limits.appFrames) { overflow += 1 }
            return overflow
        }

        mutating func addWait() { wait += 1 }

        mutating func merge(_ other: Aggregate) {
            cpu += other.cpu; wait += other.wait
            for (k, v) in other.stacks { stacks[k, default: 0] += v }
            for (k, v) in other.leaves { leaves[k, default: 0] += v }
            for (k, v) in other.images { images[k, default: 0] += v }
            for (k, v) in other.appFrames { appFrames[k, default: 0] += v }
        }

        var isEmpty: Bool { cpu == 0 && wait == 0 }
    }

    /// Highest count first, ties by key, so a report is stable.
    static func top(_ dict: [String: Int], _ n: Int) -> [(key: String, count: Int)] {
        dict.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map { (key: $0.key, count: $0.value) }
    }

    private static func percent(_ n: Int, of total: Int) -> Int {
        total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : 0
    }

    private static func ranked(_ items: [(key: String, count: Int)], total: Int) -> String {
        items.enumerated().map { "\($0 + 1)) \(percent($1.count, of: total))% (\($1.count)) \($1.key)" }.joined(separator: " | ")
    }

    /// "main stacks: cpu=… wait=… | 1) 34% (420) inner < … < outer | …": the 12 most frequent stacks of cpu samples.
    static func stacksLine(_ a: Aggregate) -> String? {
        guard !a.isEmpty else { return nil }
        let head = "main stacks: cpu=\(a.cpu) wait=\(a.wait)"
        guard a.cpu > 0 else { return head }
        return head + " | " + ranked(top(a.stacks, 12), total: a.cpu)
    }

    /// "main leaf: cpu=… | 1) 12% (n) function | …": the 15 most frequent innermost functions.
    static func leafLine(_ a: Aggregate) -> String? {
        guard a.cpu > 0 else { return nil }
        return "main leaf: cpu=\(a.cpu) | " + ranked(top(a.leaves, 15), total: a.cpu)
    }

    /// "main images: cpu=… app=34%(420) CoreBluetooth=… other=… | other: libsystem_kernel.dylib=… | uuid …".
    static func imagesLine(_ a: Aggregate, appName: String?, appUUID: String?) -> String? {
        guard a.cpu > 0 else { return nil }
        let groups = ImageGroup.named.compactMap { name -> String? in
            guard let n = a.images[name], n > 0 else { return nil }
            return "\(name)=\(percent(n, of: a.cpu))%(\(n))"
        }.joined(separator: " ")
        let detail = top(a.images.filter { $0.key.hasPrefix("other:") }, 4)
            .map { "\($0.key.dropFirst(6))=\($0.count)" }.joined(separator: " ")
        var line = "main images: cpu=\(a.cpu) \(groups)"
        if !detail.isEmpty { line += " | other: \(detail)" }
        if let appUUID { line += " | uuid \(appName ?? "app")=\(appUUID)" }
        return line
    }

    /// "main appframe: cpu=… | 1) …": the innermost frame inside the app per sample, the ten most frequent.
    static func appFrameLine(_ a: Aggregate) -> String? {
        guard a.cpu > 0 else { return nil }
        return "main appframe: cpu=\(a.cpu) | " + ranked(top(a.appFrames, 10), total: a.cpu)
    }

    /// The cost of the sampler and of the counters' own bookkeeping for a day, from its counters. nil with none booked.
    static func costLines(_ counts: [String: Int]) -> [String] {
        func v(_ c: ForkEnergyCounters.Counter) -> Int { counts[c.rawValue] ?? 0 }
        var out: [String] = []
        if v(.stackSamples) + v(.stackWaitSamples) + v(.stackDropped) > 0 {
            var parts: [String] = []
            parts.append("suspended=\(v(.stackSamples))")
            parts.append("wait=\(v(.stackWaitSamples))")
            parts.append("suspendedUs=\(v(.stackSampleUs))")
            parts.append("processMs=\(v(.stackProcessMs))")
            parts.append("watchdogMs=\(v(.stackWatchdogMs))")
            parts.append("writeMs=\(v(.stackWriteMs))")
            parts.append("dropped=\(v(.stackDropped))")
            parts.append("truncated=\(v(.stackWalkTruncated))")
            parts.append("keyOverflow=\(v(.stackKeyOverflow))")
            parts.append("frames=\(v(.stackFrames))")
            parts.append("noSymbol=\(v(.stackFramesNoSymbol))")
            out.append("main sampler cost: " + parts.joined(separator: " "))
        }
        if v(.countersFlushes) > 0 {
            var parts: [String] = []
            parts.append("flushes=\(v(.countersFlushes))")
            parts.append("flushMs=\(v(.countersFlushMs))")
            parts.append("flushMainMs=\(v(.countersFlushMainMs))")
            parts.append("bytes=\(v(.countersFlushBytes))")
            parts.append("noteOnMain=\(v(.countersNoteMain))")
            out.append("counters cost: " + parts.joined(separator: " "))
        }
        return out
    }

    // MARK: Store (aggregates per hour and per day, persisted)

    final class Store: @unchecked Sendable {
        struct Persisted: Codable { var hours: [String: Aggregate] = [:]; var days: [String: Aggregate] = [:]
                                    var appName: String?; var appUUID: String? }

        static let keptHours = 48, keptDays = 7
        private let lock = NSLock()
        private var data = Persisted()
        private let fileURL: URL?
        private var loaded = false

        init(fileURL: URL?) { self.fileURL = fileURL }

        private func loadLocked() {
            guard !loaded else { return }
            loaded = true
            guard let fileURL, let raw = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(Persisted.self, from: raw) else { return }
            data = decoded
        }

        func setApp(name: String?, uuid: String?) {
            lock.lock(); defer { lock.unlock() }
            loadLocked(); data.appName = name; data.appUUID = uuid
        }

        /// - Returns: keys refused for lack of room.
        @discardableResult
        func recordCPU(_ s: Aggregate.Sample, hour: String, day: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            var h = data.hours[hour] ?? Aggregate(), d = data.days[day] ?? Aggregate()
            let overflow = h.addCPU(s, limits: Aggregate.hourLimits) + d.addCPU(s, limits: Aggregate.dayLimits)
            data.hours[hour] = h; data.days[day] = d
            return overflow
        }

        func recordWait(hour: String, day: String) {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            data.hours[hour, default: Aggregate()].addWait()
            data.days[day, default: Aggregate()].addWait()
        }

        func day(_ day: String) -> (Aggregate, String?, String?) {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            return (data.days[day] ?? Aggregate(), data.appName, data.appUUID)
        }

        /// The last `n` hour buckets that exist, merged.
        func lastHours(_ n: Int) -> (Aggregate, String?, String?) {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            var merged = Aggregate()
            for key in data.hours.keys.sorted().suffix(n) { merged.merge(data.hours[key] ?? Aggregate()) }
            return (merged, data.appName, data.appUUID)
        }

        /// Writes the file; returns the encoded size, 0 when nothing was written.
        @discardableResult
        func persist() -> Int {
            lock.lock()
            loadLocked()
            for key in data.hours.keys.sorted().dropLast(Self.keptHours) { data.hours[key] = nil }
            for key in data.days.keys.sorted().dropLast(Self.keptDays) { data.days[key] = nil }
            let snapshot = data
            lock.unlock()
            guard let fileURL, let raw = try? JSONEncoder().encode(snapshot) else { return 0 }
            try? raw.write(to: fileURL, options: .atomic)
            return raw.count
        }
    }

    static let store = Store(fileURL: ForkEnergyCounters.defaultFileURL()?
        .deletingLastPathComponent().appendingPathComponent("main-stacks.json"))

    // MARK: Report

    private static func lines(_ a: Aggregate, appName: String?, appUUID: String?) -> [String] {
        [stacksLine(a), leafLine(a), imagesLine(a, appName: appName, appUUID: appUUID), appFrameLine(a)].compactMap { $0 }
    }

    /// The day's report lines ("<day> main stacks: …"), then the cost lines from its counters.
    static func reportLines(day: String, counts: [String: Int]) -> [String] {
        let (a, name, uuid) = store.day(day)
        return (lines(a, appName: name, appUUID: uuid) + costLines(counts)).map { "\(day) " + $0 }
    }

    /// The same four lines over the last 24 hour buckets, prefixed "last24h".
    static func last24Lines() -> [String] {
        let (a, name, uuid) = store.lastHours(24)
        return lines(a, appName: name, appUUID: uuid).map { "last24h " + $0 }
    }

    // MARK: Facade (iteration signal, start / stop)

    /// The start of the main run loop's current iteration (uptime ns), 0 between iterations. One aligned word written by
    /// the main thread and read by the watchdog, so a read is never torn.
    private static let iterationSlot: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    /// Main thread, from the run-loop observers: an iteration began at `uptimeNanos`.
    static func iterationBegan(_ uptimeNanos: UInt64) { iterationSlot.pointee = uptimeNanos }
    /// Main thread: the iteration ended.
    static func iterationEnded() { iterationSlot.pointee = 0 }

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: disableKey) }

    /// Start the watchdog. Call on the main thread, after `ForkRunLoopMeter.install()`. No-op when switched off, when
    /// already running, or off a platform that cannot sample (the watchdog exists on iOS arm64 only).
    static func start() {
        #if os(iOS) && arch(arm64)
        Live.start()
        #endif
    }

    /// Stop the watchdog (the Test Centre switch). Aggregates stay.
    static func stop() {
        #if os(iOS) && arch(arm64)
        Live.stop()
        #endif
    }
}

// MARK: - Live sampler (iOS, arm64)

#if os(iOS) && arch(arm64)
extension ForkMainStackSampler {

    /// Reads the main thread's own stack. Bounds are fixed at start.
    struct LiveStackMemory: ForkStackMemory {
        let low: UInt, high: UInt
        func load(_ address: UInt) -> UInt? {
            guard address >= low, address &+ 8 <= high, address & 7 == 0,
                  let p = UnsafePointer<UInt>(bitPattern: address) else { return nil }
            return p.pointee
        }
    }

    fileprivate enum Live {
        private static var runner: Runner?

        static func start() {
            guard pthread_main_np() != 0, runner == nil, ForkMainStackSampler.isEnabled else { return }
            ForkEnergyCounters.captureMainThreadIfNeeded()
            guard let port = ForkEnergyCounters.mainThreadPort() else { return }
            let self_ = pthread_self()
            let high = UInt(bitPattern: pthread_get_stackaddr_np(self_))
            let size = UInt(pthread_get_stacksize_np(self_))
            guard high > size else { return }
            let r = Runner(port: port, memory: LiveStackMemory(low: high - size, high: high))
            runner = r
            r.launch()
        }

        static func stop() { runner?.requestStop(); runner = nil }
    }

    fileprivate final class Runner: @unchecked Sendable {
        let port: mach_port_t
        let memory: LiveStackMemory
        private let frames: UnsafeMutablePointer<UInt>
        private let stateRaw: UnsafeMutableRawPointer
        private let stateCount: mach_msg_type_number_t
        private var stopFlag = false
        private let symbols = Symbolicator()
        private var timebase = mach_timebase_info_data_t()

        // Watchdog-thread state.
        private var prevCPU: UInt64 = 0, prevTick: UInt64 = 0, primedFor: UInt64 = 0
        private var hourIndex = -1, takenThisHour = 0
        private var hourKey = "", dayKey = "", keyStamp = -1
        private var lastFlush: UInt64 = 0, lastPersist: UInt64 = 0, lastWatchdogCPU: UInt64 = 0
        private var tally = Tally()

        struct Tally {
            var suspended = 0, wait = 0, suspendedUs = 0, processNs: UInt64 = 0, dropped = 0, truncated = 0
            var keyOverflow = 0, frames = 0, noSymbol = 0, writeNs: UInt64 = 0
        }

        init(port: mach_port_t, memory: LiveStackMemory) {
            self.port = port
            self.memory = memory
            frames = .allocate(capacity: ForkMainStackSampler.maxFrames)
            frames.initialize(repeating: 0, count: ForkMainStackSampler.maxFrames)
            let bytes = MemoryLayout<arm_thread_state64_t>.size
            stateRaw = .allocate(byteCount: bytes, alignment: 16)
            stateRaw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            stateCount = mach_msg_type_number_t(bytes / MemoryLayout<natural_t>.size)
            mach_timebase_info(&timebase)
        }

        func requestStop() { stopFlag = true }

        func launch() {
            // The app image's name and UUID, once, so a report can be symbolicated with atos.
            let (name, uuid) = Self.appImage()
            ForkMainStackSampler.store.setApp(name: name, uuid: uuid)
            // Initialise the lazy statics now, so the first suspension touches none that is still unset.
            _ = ForkMainStackSampler.iterationSlot
            _ = ForkMainStackSampler.store
            let thread = Thread { [self] in loop() }
            thread.name = "fork.stackSampler"
            thread.qualityOfService = .utility
            thread.start()
        }

        private func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        private func machToNanos(_ t: UInt64) -> UInt64 { t &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom)) }

        private func loop() {
            let slot = ForkMainStackSampler.iterationSlot
            lastFlush = nowNanos(); lastPersist = lastFlush
            while !stopFlag {
                usleep(ForkMainStackSampler.tickMicros)
                if stopFlag { break }
                let now = nowNanos()
                housekeeping(now)
                let start = slot.pointee
                guard start != 0, now &- start >= ForkMainStackSampler.primeNanos else { primedFor = 0; continue }
                guard let cpu = Self.threadCPUMicros(port) else { continue }
                let primed = primedFor == start
                let intervalUs = primed ? (now &- prevTick) / 1000 : 0
                let delta = cpu &- prevCPU
                prevCPU = cpu; prevTick = now; primedFor = start
                guard now &- start >= ForkRunLoopMeter.slowThresholdNs else { continue }
                guard primed else { tally.dropped += 1; continue }
                refreshKeys()
                guard ForkMainStackSampler.isCPUSample(cpuDeltaMicros: delta, intervalMicros: intervalUs) else {
                    tally.wait += 1
                    ForkMainStackSampler.store.recordWait(hour: hourKey, day: dayKey)
                    continue
                }
                sample()
            }
        }

        /// One suspending sample. The window between suspend and resume touches only preallocated memory.
        private func sample() {
            let hour = Int(time(nil) / 3600)
            if hour != hourIndex { hourIndex = hour; takenThisHour = 0 }
            guard takenThisHour < ForkMainStackSampler.samplesPerHourCap else { tally.dropped += 1; return }
            takenThisHour += 1

            let port = self.port, frames = self.frames, memory = self.memory
            let state = stateRaw.assumingMemoryBound(to: natural_t.self)
            let words = UnsafeRawPointer(stateRaw).assumingMemoryBound(to: UInt64.self)
            var count = stateCount
            var walked: (count: Int, truncated: Bool) = (0, false)
            let t0 = mach_absolute_time()
            if thread_suspend(port) == KERN_SUCCESS {
                if thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), state, &count) == KERN_SUCCESS {
                    // arm_thread_state64_t: x0-x28, fp, lr, sp, pc, cpsr.
                    walked = StackWalker.walk(pc: UInt(words[32]), lr: UInt(words[30]), fp: UInt(words[29]),
                                              memory: memory, maxFrames: ForkMainStackSampler.maxFrames, out: frames)
                }
                thread_resume(port)
            }
            let t1 = mach_absolute_time()
            tally.suspended += 1
            tally.suspendedUs += Int(machToNanos(t1 &- t0) / 1000)
            guard walked.count > 0 else { tally.dropped += 1; return }
            if walked.truncated { tally.truncated += 1 }

            let p0 = nowNanos()
            var names: [String] = []
            names.reserveCapacity(walked.count)
            var imageGroup = ImageGroup.other, imageDetail: String?
            var appFrame = "none"
            for i in 0..<walked.count {
                let r = symbols.resolve(frames[i], leaf: i == 0)
                tally.frames += 1
                if !r.symbolized { tally.noSymbol += 1 }
                names.append(r.name)
                if i == 0 {
                    imageGroup = r.group
                    if r.group == ImageGroup.other { imageDetail = "other:" + r.base }
                }
                if appFrame == "none", r.group == ImageGroup.app { appFrame = String(r.name.prefix(80)) }
            }
            let sample = Aggregate.Sample(frames: names.map { String($0.prefix(60)) }, imageGroup: imageGroup,
                                          imageDetail: imageDetail, appFrame: appFrame)
            tally.keyOverflow += ForkMainStackSampler.store.recordCPU(sample, hour: hourKey, day: dayKey)
            tally.processNs &+= nowNanos() &- p0
        }

        private func refreshKeys() {
            let stamp = Int(time(nil) / 60)
            guard stamp != keyStamp else { return }
            keyStamp = stamp
            let key = ForkEnergyCounters.bucket(for: Date(), timeZone: .current)
            hourKey = key
            dayKey = String(key.prefix(10))
        }

        private func housekeeping(_ now: UInt64) {
            if now &- lastFlush >= ForkMainStackSampler.flushIntervalNanos {
                lastFlush = now
                flushTally()
            }
            if now &- lastPersist >= ForkMainStackSampler.persistIntervalNanos {
                lastPersist = now
                let w0 = nowNanos()
                ForkMainStackSampler.store.persist()
                tally.writeNs &+= nowNanos() &- w0
            }
        }

        private func flushTally() {
            let c = ForkEnergyCounters.shared
            let cpuNow = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let watchdogMs = Int((cpuNow &- lastWatchdogCPU) / 1_000_000)
            lastWatchdogCPU &+= UInt64(watchdogMs) * 1_000_000
            c.note(.stackSamples, by: tally.suspended)
            c.note(.stackWaitSamples, by: tally.wait)
            c.note(.stackSampleUs, by: tally.suspendedUs)
            c.note(.stackProcessMs, by: Int(tally.processNs / 1_000_000))
            c.note(.stackDropped, by: tally.dropped)
            c.note(.stackWalkTruncated, by: tally.truncated)
            c.note(.stackKeyOverflow, by: tally.keyOverflow)
            c.note(.stackFrames, by: tally.frames)
            c.note(.stackFramesNoSymbol, by: tally.noSymbol)
            c.note(.stackWriteMs, by: Int(tally.writeNs / 1_000_000))
            c.note(.stackWatchdogMs, by: watchdogMs)
            tally.suspended = 0; tally.wait = 0; tally.suspendedUs = 0; tally.dropped = 0; tally.truncated = 0
            tally.keyOverflow = 0; tally.frames = 0; tally.noSymbol = 0
            tally.processNs %= 1_000_000; tally.writeNs %= 1_000_000
        }

        /// User + system CPU of a thread, microseconds. No allocation: the struct lives on the stack.
        static func threadCPUMicros(_ port: mach_port_t) -> UInt64? {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return nil }
            func us(_ t: time_value_t) -> UInt64 { UInt64(t.seconds) &* 1_000_000 &+ UInt64(t.microseconds) }
            return us(info.user_time) &+ us(info.system_time)
        }

        /// The main executable's basename and LC_UUID.
        static func appImage() -> (String?, String?) {
            guard let header = _dyld_get_image_header(0) else { return (nil, nil) }
            var name: String?
            if let raw = _dyld_get_image_name(0) { name = String(cString: raw).split(separator: "/").last.map(String.init) }
            return (name, imageUUID(UnsafeRawPointer(header)))
        }

        static func imageUUID(_ base: UnsafeRawPointer) -> String? {
            let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
            guard header.magic == MH_MAGIC_64 else { return nil }
            var cursor = base + MemoryLayout<mach_header_64>.size
            for _ in 0..<header.ncmds {
                let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
                if cmd.cmd == UInt32(LC_UUID) {
                    return UUID(uuid: cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
                }
                cursor += Int(cmd.cmdsize)
            }
            return nil
        }
    }

    /// Address to name, with a bounded cache. Runs on the watchdog thread, never while the main thread is suspended.
    fileprivate final class Symbolicator {
        struct Resolved { var name: String; var group: String; var base: String; var symbolized: Bool }

        private var cache: [UInt: Resolved] = [:]
        private let appBundlePath = Bundle.main.bundlePath
        private typealias DemangleFn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                       UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        private let demangle: DemangleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: DemangleFn.self) }

        /// A return address points after the call, so every frame but the innermost looks one byte back.
        func resolve(_ address: UInt, leaf: Bool) -> Resolved {
            let key = leaf ? address : address &- 1
            if let hit = cache[key] { return hit }
            if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
            let r = lookup(key)
            cache[key] = r
            return r
        }

        private func lookup(_ key: UInt) -> Resolved {
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: key), dladdr(pointer, &info) != 0 else {
                return Resolved(name: "?+0x" + String(key, radix: 16), group: ImageGroup.other, base: "?", symbolized: false)
            }
            let path = info.dli_fname.map { String(cString: $0) } ?? ""
            let (group, base) = ImageGroup.classify(path: path, appBundlePath: appBundlePath)
            if let symbol = info.dli_sname {
                return Resolved(name: demangled(String(cString: symbol)), group: group, base: base, symbolized: true)
            }
            // No symbol: image and offset from its header, the pair `atos -l <header>` resolves with the dSYM.
            let offset = key &- UInt(bitPattern: info.dli_fbase)
            return Resolved(name: base + "+0x" + String(offset, radix: 16), group: group, base: base, symbolized: false)
        }

        private func demangled(_ name: String) -> String {
            guard let demangle, name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") else { return name }
            return name.withCString { cString in
                guard let out = demangle(cString, strlen(cString), nil, nil, 0) else { return name }
                defer { free(out) }
                return String(cString: out)
            }
        }
    }
}
#endif
