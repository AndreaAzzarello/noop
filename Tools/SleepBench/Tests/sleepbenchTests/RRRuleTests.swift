import XCTest
import SQLite3
@testable import sleepbench

/// The bench has to read the R-R the app's stagers are handed, not every row in the table. These tests pin
/// `ReadOnlyDB.rrQuery` against a synthetic database: nothing here is, or is derived from, a wearer's data.
final class RRRuleTests: XCTestCase {

    private func makeDatabase(_ statements: [String]) throws -> ReadOnlyDB {
        let path = NSTemporaryDirectory() + "rrrule-\(UUID().uuidString).sqlite"
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql) }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return try ReadOnlyDB(path: path)
    }

    private func rows(_ db: ReadOnlyDB, device: String, from: Int, to: Int, rule: RRRule) throws -> [(ts: Int, rr: Int)] {
        var out: [(ts: Int, rr: Int)] = []
        try db.query(try db.rrQuery(device: device, from: from, to: to, rule: rule)) { s in
            out.append((ReadOnlyDB.int(s, 0), ReadOnlyDB.int(s, 1)))
        }
        return out
    }

    private let schema = """
        CREATE TABLE rrInterval (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL,
                                 seq INTEGER NOT NULL DEFAULT 0, ord INTEGER, srcChannel INTEGER, tsSuspect INTEGER)
        """

    /// Channel 5 and channel 7 hold the same ten beats, as on a real 5.0; one channel-5 beat is flagged.
    private func twoChannelStatements() -> [String] {
        var sql = [schema]
        for i in 0..<10 {
            sql.append("INSERT INTO rrInterval (deviceId, ts, rrMs, ord, srcChannel, tsSuspect) VALUES ('w5', \(100 + i), \(1000 + i), 0, 5, \(i == 3 ? "1" : "NULL"))")
            sql.append("INSERT INTO rrInterval (deviceId, ts, rrMs, ord, srcChannel, tsSuspect) VALUES ('w5', \(100 + i), \(1000 + i), 0, 7, NULL)")
        }
        return sql
    }

    func testAppRuleReadsOneChannelAndSkipsSuspectBeats() throws {
        let db = try makeDatabase(twoChannelStatements())
        let app = try rows(db, device: "w5", from: 100, to: 109, rule: .app)
        XCTAssertEqual(app.count, 9, "channel 5 only, minus the one tsSuspect beat")
        XCTAssertEqual(app.map { $0.ts }, [100, 101, 102, 104, 105, 106, 107, 108, 109])
    }

    func testAllRowsRuleKeepsTheDoubledStream() throws {
        let db = try makeDatabase(twoChannelStatements())
        XCTAssertEqual(try rows(db, device: "w5", from: 100, to: 109, rule: .allRows).count, 20)
    }

    func testAWindowWithOnlyTheStandardChannelReadsIt() throws {
        var sql = twoChannelStatements()
        for i in 0..<5 {
            sql.append("INSERT INTO rrInterval (deviceId, ts, rrMs, ord, srcChannel) VALUES ('w5', \(200 + i), \(900 + i), 0, 7)")
        }
        let db = try makeDatabase(sql)
        let live = try rows(db, device: "w5", from: 200, to: 204, rule: .app)
        XCTAssertEqual(live.map { $0.rr }, [900, 901, 902, 903, 904], "no channel 5 in this window, so channel 7 is the one read")
    }

    func testChoiceIsPerWindowNotPerDevice() throws {
        var sql = twoChannelStatements()
        sql.append("INSERT INTO rrInterval (deviceId, ts, rrMs, ord, srcChannel) VALUES ('w5', 200, 900, 0, 7)")
        let db = try makeDatabase(sql)
        // A window that spans both places sees channel 5 present and so pins to it, dropping the lone 7 beat.
        XCTAssertEqual(try rows(db, device: "w5", from: 100, to: 200, rule: .app).count, 9)
        XCTAssertEqual(try rows(db, device: "w5", from: 200, to: 200, rule: .app).count, 1)
    }

    func testADeviceWithoutLabelledChannelsKeepsEveryNonSuspectBeat() throws {
        var sql = [schema]
        for i in 0..<6 {
            sql.append("INSERT INTO rrInterval (deviceId, ts, rrMs, ord, srcChannel, tsSuspect) VALUES ('plain', \(10 + i), \(800 + i), 0, NULL, \(i == 0 ? "1" : "NULL"))")
        }
        let db = try makeDatabase(sql)
        XCTAssertEqual(try rows(db, device: "plain", from: 0, to: 100, rule: .app).count, 5)
    }

    func testCsvNightCountsSeparateDictionaryRowsFromTimelinesAndFindOverlap() throws {
        var sql = ["CREATE TABLE sleepSession (deviceId TEXT, startTs INTEGER, endTs INTEGER, stagesJSON TEXT)",
                   "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)"]
        sql.append("INSERT INTO sleepSession VALUES ('d', 0, 1000, '{\"light\":300,\"deep\":60}')")        // csv, covered
        sql.append("INSERT INTO sleepSession VALUES ('d', 5000, 6000, ' {\"light\":10}')")                   // csv, uncovered
        sql.append("INSERT INTO sleepSession VALUES ('d', 9000, 9600, '[{\"start\":9000,\"end\":9600,\"stage\":\"light\"}]')")
        sql.append("INSERT INTO sleepSession VALUES ('other', 0, 1000, '{\"light\":1}')")
        for ts in 0..<800 { sql.append("INSERT INTO hrSample VALUES ('s', \(ts), 55)") }
        let db = try makeDatabase(sql)
        let r = try db.csvNightCounts(sessionDevice: "d", streamDevice: "s")
        XCTAssertEqual(r.csv, 2)
        XCTAssertEqual(r.withRawStreams, 1)
    }
}
