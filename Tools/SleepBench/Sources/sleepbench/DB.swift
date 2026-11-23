import Foundation
import SQLite3
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Minimal read-only SQLite reader. Deliberately not GRDB: this tool must be able to open a COPY of a
/// device database taken at any schema version, including one older or newer than `WhoopStore`'s current
/// migration set, without running migrations against it. Opened `immutable=1` so it can never write.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        // `immutable=1` promises the file will not change under us and suppresses any journal/WAL
        // recovery write — the reason a plain read-only open is not enough for a pulled device DB.
        let uri = "file:\(path)?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            throw Err("cannot open \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Run `sql` and hand each row to `each` as a statement cursor.
    func query(_ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt!) }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    static func dbl(_ s: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(s, i) }
    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool {
        sqlite3_column_type(s, i) == SQLITE_NULL
    }
    static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}

// MARK: - Rows

/// One persisted night. `stagesJSON` is the hypnogram CURRENTLY stored; on a `userEdited` row that is the
/// wearer's manual restage, and `efficiency` is then the STALE pre-edit machine value (the edit path
/// rewrites the stages but not the summary column) — which is exactly what makes the machine's original
/// wake total recoverable. See `MachineRecall` in main.swift for the check that establishes this.
struct SessionRow {
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let efficiency: Double?
    let userEdited: Bool
    let startTsAdjusted: Int?
    let stages: [StageSegment]
    let bandStates: [Int]        // persisted per-epoch sleepStateJSON, [] when absent
    var durMin: Double { Double(endTs - startTs) / 60.0 }
}

struct Streams {
    var hr: [HRSample] = []
    var rr: [RRInterval] = []
    var grav: [GravitySample] = []
    var resp: [RespSample] = []
    var steps: [StepSample] = []
    var band: [(ts: Int, state: Int)] = []
}

/// Which R-R rows a replay reads.
///
/// `.app` mirrors what the app's stagers are actually handed: `WhoopStore.rrIntervals` (Reads.swift,
/// Whoop5RRReadPolicy.swift) reads ONE transport per requested window for a WHOOP 5 — the lowest of
/// channels 5 (v18 history) and 7 (standard BLE heart rate) present, never both — and skips beats flagged
/// `tsSuspect` (future-stamped, or the strap's 500 ms fill). The two channels carry the same beats, so
/// reading both feeds the stager every beat twice, which no scored night in the app ever sees.
/// `.allRows` is the previous behaviour, kept only so the size of that difference can be measured.
///
/// Mirrored: the WHOOP 5 rule. Not mirrored: the WHOOP 4 per-hour source choice and the Oura per-hour
/// choice, which this bench never replayed; a device with no channel 5/7 rows keeps every non-suspect row.
enum RRRule { case app, allRows }

extension ReadOnlyDB {
    /// Column names of `rrInterval`: a copy taken at an older schema has neither `srcChannel` nor `tsSuspect`.
    func rrColumns() throws -> Set<String> {
        var names: Set<String> = []
        try query("PRAGMA table_info(rrInterval)") { if let n = ReadOnlyDB.str($0, 1) { names.insert(n) } }
        return names
    }

    /// True when the device has any WHOOP 5 labelled beat, which is what puts it under the strict rule.
    func isWhoop5RR(device: String) throws -> Bool {
        guard try rrColumns().contains("srcChannel") else { return false }
        var found = false
        try query("SELECT 1 FROM rrInterval WHERE deviceId = '\(device)' AND srcChannel IN (5, 7) LIMIT 1") { _ in found = true }
        return found
    }

    /// The `SELECT` that returns `device`'s R-R over `[from, to]` under `rule`, in the app's read order.
    func rrQuery(device: String, from: Int, to: Int, rule: RRRule) throws -> String {
        let w = "deviceId = '\(device)' AND ts >= \(from) AND ts <= \(to)"
        let order = "ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC"
        let notSuspect = try rrColumns().contains("tsSuspect") ? "(tsSuspect IS NULL OR tsSuspect <> 1)" : "1"
        switch rule {
        case .allRows:
            return "SELECT ts, rrMs FROM rrInterval WHERE \(w) ORDER BY ts, ord, seq"
        case .app:
            if try isWhoop5RR(device: device) {
                return """
                SELECT ts, rrMs FROM rrInterval WHERE \(w) AND \(notSuspect)
                AND srcChannel = (SELECT MIN(srcChannel) FROM rrInterval
                                  WHERE \(w) AND srcChannel IN (5, 7) AND \(notSuspect))
                \(order)
                """
            }
            return "SELECT ts, rrMs FROM rrInterval WHERE \(w) AND \(notSuspect) \(order)"
        }
    }

    /// Every non-suspect WHOOP 5 R-R row over `[from, to]` with its transport (`srcChannel`), in the raw-dump
    /// order (`ts, ord, rrMs, seq`). Only for the R-R duplication measurement: scoring reads go through `rrQuery`.
    func rrWithChannel(device: String, from: Int, to: Int) throws -> [(ts: Int, rr: Int, ch: Int)] {
        var out: [(ts: Int, rr: Int, ch: Int)] = []
        try query("""
            SELECT ts, rrMs, srcChannel FROM rrInterval
            WHERE deviceId = '\(device)' AND ts >= \(from) AND ts <= \(to) AND srcChannel IN (5, 7)
              AND (tsSuspect IS NULL OR tsSuspect <> 1)
            ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
            """) { s in out.append((ReadOnlyDB.int(s, 0), ReadOnlyDB.int(s, 1), ReadOnlyDB.int(s, 2))) }
        return out
    }

    /// Sessions the WHOOP CSV import wrote (`stagesJSON` is a per-stage minutes dictionary, no timeline) and how
    /// many of those also have recorded heart rate over more than half their span. Only the latter could be
    /// scored against a replay, and the dictionary has totals only, so it can never be an epoch reference.
    func csvNightCounts(sessionDevice: String, streamDevice: String) throws -> (csv: Int, withRawStreams: Int) {
        var spans: [(Int, Int)] = []
        try query("""
            SELECT startTs, endTs FROM sleepSession
            WHERE deviceId = '\(sessionDevice)' AND stagesJSON IS NOT NULL AND ltrim(stagesJSON) LIKE '{%'
            """) { s in spans.append((ReadOnlyDB.int(s, 0), ReadOnlyDB.int(s, 1))) }
        var overlapping = 0
        for (from, to) in spans {
            var n = 0
            try query("SELECT COUNT(*) FROM hrSample WHERE deviceId = '\(streamDevice)' AND ts >= \(from) AND ts <= \(to)") {
                n = ReadOnlyDB.int($0, 0)
            }
            if Double(n) > 0.5 * Double(to - from) { overlapping += 1 }
        }
        return (spans.count, overlapping)
    }

    func sessions(device: String) throws -> [SessionRow] {
        var out: [SessionRow] = []
        let sql = """
        SELECT startTs, endTs, efficiency, userEdited, startTsAdjusted, stagesJSON, sleepStateJSON
        FROM sleepSession WHERE deviceId = '\(device)' ORDER BY startTs
        """
        try query(sql) { s in
            let stagesJSON = ReadOnlyDB.str(s, 5) ?? "[]"
            let stages = (try? JSONDecoder().decode([StageSegment].self,
                                                    from: Data(stagesJSON.utf8))) ?? []
            var band: [Int] = []
            if let bj = ReadOnlyDB.str(s, 6) {
                band = (try? JSONDecoder().decode([Int].self, from: Data(bj.utf8))) ?? []
            }
            out.append(SessionRow(
                deviceId: device,
                startTs: ReadOnlyDB.int(s, 0),
                endTs: ReadOnlyDB.int(s, 1),
                efficiency: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.dbl(s, 2),
                userEdited: ReadOnlyDB.int(s, 3) != 0,
                startTsAdjusted: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.int(s, 4),
                stages: stages,
                bandStates: band))
        }
        return out
    }

    /// Every stream the stagers read, over `[from, to]`. The stagers themselves clip to the window they
    /// need, but detection wants a wider span than the session, hence the caller-chosen padding.
    func streams(device: String, from: Int, to: Int, rrRule: RRRule = .app) throws -> Streams {
        var st = Streams()
        let w = "deviceId = '\(device)' AND ts >= \(from) AND ts <= \(to)"
        try query("SELECT ts, bpm FROM hrSample WHERE \(w) ORDER BY ts") { s in
            st.hr.append(HRSample(ts: ReadOnlyDB.int(s, 0), bpm: ReadOnlyDB.int(s, 1)))
        }
        // `ord` then `seq` preserves the within-second beat order the store guarantees.
        try query(try rrQuery(device: device, from: from, to: to, rule: rrRule)) { s in
            st.rr.append(RRInterval(ts: ReadOnlyDB.int(s, 0), rrMs: ReadOnlyDB.int(s, 1)))
        }
        try query("SELECT ts, x, y, z, dynAccel FROM gravitySample WHERE \(w) ORDER BY ts") { s in
            st.grav.append(GravitySample(
                ts: ReadOnlyDB.int(s, 0), x: ReadOnlyDB.dbl(s, 1), y: ReadOnlyDB.dbl(s, 2),
                z: ReadOnlyDB.dbl(s, 3), unit: "g",
                dynAccel: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.dbl(s, 4)))
        }
        // An Oura ring's respiration rows are its OWN per-window rate (0x6A, milli-bpm), stored as
        // instrumentation; the stagers read this stream as a ~1 Hz raw ADC waveform. The app refuses
        // them by provenance at every scoring read, so the bench must refuse them the same way or it
        // would score a night the app cannot produce. Same seam, one line: `OuraRespScale.forScoring`.
        if !OuraRespScale.isRingRateStream(deviceId: device) {
            try query("SELECT ts, raw FROM respSample WHERE \(w) ORDER BY ts") { s in
                st.resp.append(RespSample(ts: ReadOnlyDB.int(s, 0), raw: ReadOnlyDB.int(s, 1)))
            }
        }
        try query("SELECT ts, counter, activityClass FROM stepSample WHERE \(w) ORDER BY ts") { s in
            st.steps.append(StepSample(
                ts: ReadOnlyDB.int(s, 0), counter: ReadOnlyDB.int(s, 1),
                activityClass: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.int(s, 2)))
        }
        try query("SELECT ts, state FROM sleepStateSample WHERE \(w) ORDER BY ts") { s in
            st.band.append((ts: ReadOnlyDB.int(s, 0), state: ReadOnlyDB.int(s, 1)))
        }
        return st
    }

    /// The `stagelock:<deviceId>:<startTs>` cursors. A lock is written ONLY by `CloudEditApplier` when an
    /// `edit_sleep_stages` payload lands — i.e. only when a human authored the hypnogram itself, as opposed
    /// to correcting the bed/wake bounds (which re-derives stages from raw and is therefore machine output
    /// over a human-chosen window). This distinction decides whether a `userEdited` row is usable as a
    /// stage-level reference at all, so the harness reads it rather than assuming.
    func stageLockedStarts(device: String) throws -> Set<Int> {
        var out: Set<Int> = []
        let prefix = "stagelock:\(device):"
        try query("SELECT name FROM cursors WHERE value = 1 AND name LIKE '\(prefix)%'") { s in
            if let n = ReadOnlyDB.str(s, 0), let ts = Int(n.dropFirst(prefix.count)) { out.insert(ts) }
        }
        return out
    }

    /// Mean / min HR over a window — the stratifier for the supplement-HR hypothesis.
    func hrStats(device: String, from: Int, to: Int) throws -> (mean: Double, n: Int, p10: Double)? {
        var v: [Double] = []
        try query("SELECT bpm FROM hrSample WHERE deviceId = '\(device)' AND ts >= \(from) AND ts <= \(to)") { s in
            v.append(ReadOnlyDB.dbl(s, 0))
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return (v.reduce(0, +) / Double(v.count), v.count, v[max(0, Int(Double(v.count) * 0.10) - 1)])
    }
}
