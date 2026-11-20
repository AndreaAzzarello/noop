import Foundation
import StrandImport

/// A ledger of what the Apple Health write-back last wrote, so a pass rewrites only what changed.
///
/// WHY. Every offload (about every 15 minutes) ends in a write-back that deleted and re-saved the last 14 days of
/// vitals, sleep and workouts and the whole 48 h of 1-minute heart rate, whether or not anything had moved. Health
/// re-indexes every one of those samples (and our own observers wake for each), so Health's own battery line rose
/// and fell with NOOP's.
///
/// MODEL. Each section (vitals, sleep, heart rate, workouts) keeps `key → fingerprint` of the last successful write.
/// A pass fingerprints what it WOULD write and rewrites only the keys that are new or differ. The delete-then-save
/// per key is unchanged, so the dedup the bridge relies on (external UUID + our own source) still holds.
///
/// SAFETY RULES (each one has a test):
///  - The ledger moves only after the section's save succeeded (`commit`). It is never advanced optimistically.
///  - Any failed delete or save invalidates the section: the next pass rewrites all of it.
///  - A section is rewritten in full when it has no entry, is older than 24 h, was written by another build or for
///    another strap, or the switch is off. A sample the user deleted in Health therefore comes back within a day.
///  - Switched off, the ledger is cleared on every pass, so switching it on never trusts an old entry.
///
/// Pure value logic plus a small file-backed store; no HealthKit, so the table of cases runs in `StrandTests`.
struct HealthWriteBackLedger: Codable, Equatable {

    enum Section: String, Codable, CaseIterable {
        case vitals, sleep, heartRate, workouts
    }

    struct SectionState: Codable, Equatable {
        /// When the last FULL rewrite of this section finished (the TTL clock).
        var fullRewriteAt: TimeInterval
        var build: String
        var scope: String
        /// key → fingerprint, hex (a 64-bit value does not survive a JSON number).
        var fingerprints: [String: String]
    }

    /// What one pass should do for one section.
    struct Plan: Equatable {
        let section: Section
        let scope: String
        let build: String
        /// The complete picture this pass would write: key → fingerprint.
        let desired: [String: UInt64]
        /// True when the whole section is rewritten (and `dirty` is every key).
        let fullRewrite: Bool
        /// Keys to delete and save again.
        let dirty: Set<String>
        /// Keys the ledger holds that this pass no longer produces.
        let removed: [String]

        var unchangedCount: Int { desired.count - dirty.intersection(desired.keys).count }
    }

    /// Full-rewrite TTL.
    static let ttl: TimeInterval = 24 * 3600

    private(set) var sections: [String: SectionState] = [:]

    func plan(_ section: Section, desired: [String: UInt64], scope: String, build: String,
              now: Date, enabled: Bool) -> Plan {
        let all = Set(desired.keys)
        func full() -> Plan {
            Plan(section: section, scope: scope, build: build, desired: desired, fullRewrite: true,
                 dirty: all, removed: sections[section.rawValue].map { Array(Set($0.fingerprints.keys).subtracting(all)).sorted() } ?? [])
        }
        guard enabled, let state = sections[section.rawValue], state.build == build, state.scope == scope else {
            return full()
        }
        // `age >= 0` on purpose: wall-clock time can move backwards (NTP, a changed date). A negative age must read
        // as "do not trust" rather than "fresh forever".
        let age = now.timeIntervalSince1970 - state.fullRewriteAt
        guard age >= 0, age < Self.ttl else { return full() }
        var dirty = Set<String>()
        for (key, fp) in desired where state.fingerprints[key] != Self.hex(fp) { dirty.insert(key) }
        let removed = Set(state.fingerprints.keys).subtracting(all).sorted()
        return Plan(section: section, scope: scope, build: build, desired: desired, fullRewrite: false,
                    dirty: dirty, removed: removed)
    }

    /// Record a SUCCESSFUL pass. Call only after every delete and save the plan asked for returned.
    mutating func commit(_ plan: Plan, now: Date) {
        let fingerprints = plan.desired.mapValues(Self.hex)
        if plan.fullRewrite {
            sections[plan.section.rawValue] = SectionState(fullRewriteAt: now.timeIntervalSince1970, build: plan.build,
                                                           scope: plan.scope, fingerprints: fingerprints)
        } else if var state = sections[plan.section.rawValue] {
            state.fingerprints = fingerprints
            sections[plan.section.rawValue] = state
        }
    }

    mutating func invalidate(_ section: Section) { sections[section.rawValue] = nil }
    mutating func invalidateAll() { sections = [:] }

    static func hex(_ value: UInt64) -> String { String(value, radix: 16) }
}

// MARK: - Fingerprints

/// FNV-1a over a canonical byte stream. Deterministic across launches and platforms (`Hasher` is randomised per
/// process, which would make every launch a full rewrite).
struct LedgerFingerprint {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    private mutating func byte(_ b: UInt8) { value = (value ^ UInt64(b)) &* 0x100000001b3 }

    mutating func add(_ s: String) {
        for b in s.utf8 { byte(b) }
        byte(0x1f)
    }
    mutating func add(_ i: Int) { add(String(i)) }
    mutating func add(_ d: Double) { add(String(d.bitPattern, radix: 16)) }
    mutating func add(_ d: Double?) { if let d { add(d) } else { add("nil") } }
}

/// The keys and fingerprints each section writes. Pure, so tests pin them.
enum HealthWriteBackLedgerKeys {

    static func vital(value: Double, at: Date) -> UInt64 {
        var f = LedgerFingerprint(); f.add("v"); f.add(value); f.add(at.timeIntervalSince1970); return f.value
    }

    /// A retraction (delete with no replacement) is tracked too, so it is not re-issued every pass.
    static let retracted: UInt64 = {
        var f = LedgerFingerprint(); f.add("retracted"); return f.value
    }()

    static func sleep(_ entry: HealthWriteback.MergedSleepEntry) -> UInt64 {
        var f = LedgerFingerprint()
        f.add("s"); f.add(entry.spanStart); f.add(entry.spanEnd)
        for k in entry.allKeyStartTs { f.add(k) }
        f.add("|")
        for i in entry.intervals { f.add(i.start); f.add(i.end); f.add("\(i.kind)") }
        return f.value
    }

    static let hourSeconds = 3600

    /// Heart-rate buckets grouped by clock hour: `hour index → fingerprint`. An hour is the unit that is deleted and
    /// rewritten, so only the hours an offload touched cost a write.
    static func hourBlocks(_ buckets: [(ts: Int, bpm: Double)]) -> [Int: UInt64] {
        var fps: [Int: LedgerFingerprint] = [:]
        for b in buckets.sorted(by: { $0.ts < $1.ts }) {
            let hour = b.ts / hourSeconds
            var f = fps[hour] ?? LedgerFingerprint()
            f.add(b.ts); f.add(b.bpm)
            fps[hour] = f
        }
        return fps.mapValues(\.value)
    }

    static func hourKey(_ hour: Int) -> String { String(hour) }

    /// Consecutive hour indexes folded into `[first, last]` runs, so one delete covers a whole run.
    static func runs(of hours: [Int]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for h in Set(hours).sorted() {
            if let last = out.last, last.upperBound + 1 == h { out[out.count - 1] = last.lowerBound...h }
            else { out.append(h...h) }
        }
        return out
    }

    /// The unix-second range one run of hours covers for a delete: `[start, end]` with the end one second short of
    /// the next hour, so a sample starting exactly on the next hour is never inside it whichever way the store
    /// treats the boundary.
    static func deleteRange(for run: ClosedRange<Int>) -> (start: Int, end: Int) {
        (run.lowerBound * hourSeconds, (run.upperBound + 1) * hourSeconds - 1)
    }

    /// The fields of a workout row that end up in Health, plus a token for the route that would be attached.
    static func workout(startTs: Int, endTs: Int, sport: String, energyKcal: Double?, distanceM: Double?,
                        routeToken: Int) -> UInt64 {
        var f = LedgerFingerprint()
        f.add("w"); f.add(startTs); f.add(endTs); f.add(sport); f.add(energyKcal); f.add(distanceM); f.add(routeToken)
        return f.value
    }
}

// MARK: - Store

/// File-backed holder of the ledger, plus the consecutive-failure count that decides when a failing delete is shown.
final class HealthWriteBackLedgerStore: @unchecked Sendable {

    static let shared = HealthWriteBackLedgerStore(fileURL: HealthWriteBackLedgerStore.defaultFileURL())

    /// Test Centre switch. Default ON.
    static let switchKey = "fork.healthWriteBackLedger"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: switchKey) as? Bool ?? true }

    /// A failing delete is surfaced in `lastError` only from this many passes in a row.
    static let surfaceAfterFailures = 3

    static func currentBuild() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v)+\(b)"
    }

    private let lock = NSLock()
    private let fileURL: URL?
    let build: String
    private var ledger = HealthWriteBackLedger()
    private var loaded = false
    private var failures: [HealthWriteBackLedger.Section: Int] = [:]

    init(fileURL: URL?, build: String = HealthWriteBackLedgerStore.currentBuild()) {
        self.fileURL = fileURL
        self.build = build
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ForkPerf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("healthwriteback-ledger.json")
    }

    func plan(_ section: HealthWriteBackLedger.Section, desired: [String: UInt64], scope: String,
              now: Date = Date(), enabled: Bool = HealthWriteBackLedgerStore.isEnabled) -> HealthWriteBackLedger.Plan {
        lock.lock(); defer { lock.unlock() }
        load()
        if !enabled, !ledger.sections.isEmpty { ledger.invalidateAll(); save() }
        return ledger.plan(section, desired: desired, scope: scope, build: build, now: now, enabled: enabled)
    }

    /// After a successful pass only. A no-op while the switch is off, so nothing is trusted later.
    func commit(_ plan: HealthWriteBackLedger.Plan, now: Date = Date(),
                enabled: Bool = HealthWriteBackLedgerStore.isEnabled) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        load()
        ledger.commit(plan, now: now)
        failures[plan.section] = 0
        save()
    }

    func invalidate(_ section: HealthWriteBackLedger.Section) {
        lock.lock(); defer { lock.unlock() }
        load()
        ledger.invalidate(section)
        save()
    }

    /// End of a section's pass: commit it, unless a delete failed, in which case the section is invalidated so the
    /// next pass rewrites all of it.
    func settle(_ plan: HealthWriteBackLedger.Plan, deleteFailed: Bool, now: Date = Date(),
                enabled: Bool = HealthWriteBackLedgerStore.isEnabled) {
        if deleteFailed { invalidate(plan.section) } else { commit(plan, now: now, enabled: enabled) }
    }

    /// Count a failed delete or save of `section`; true once it has failed enough passes in a row to be shown.
    @discardableResult
    func recordFailure(_ section: HealthWriteBackLedger.Section) -> Bool {
        lock.lock(); defer { lock.unlock() }
        load()
        ledger.invalidate(section)
        save()
        failures[section, default: 0] += 1
        return failures[section, default: 0] >= Self.surfaceAfterFailures
    }

    func recordSuccess(_ section: HealthWriteBackLedger.Section) {
        lock.lock(); defer { lock.unlock() }
        failures[section] = 0
    }

    func snapshot() -> HealthWriteBackLedger {
        lock.lock(); defer { lock.unlock() }
        load()
        return ledger
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(HealthWriteBackLedger.self, from: data) else { return }
        ledger = decoded
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
