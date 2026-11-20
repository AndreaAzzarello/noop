import XCTest
@testable import Strand

// fork-perf: TEMP — tests for the energy audit counters.
final class ForkEnergyCountersTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fork-energy-\(UUID().uuidString).json")
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testBucketIsHourInGivenTimeZone() {
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T10:59:59Z"), timeZone: utc), "2026-11-20 10")
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T11:00:00Z"), timeZone: utc), "2026-11-20 11")
        let rome = TimeZone(identifier: "Europe/Rome")!
        XCTAssertEqual(ForkEnergyCounters.bucket(for: date("2026-11-20T10:00:00Z"), timeZone: rome), "2026-11-20 11")
    }

    func testCountsAccumulatePerHour() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkObserverWake, at: date("2026-11-20T10:05:00Z"))
        c.note(.hkObserverWake, at: date("2026-11-20T10:50:00Z"))
        c.note(.hkObserverWake, at: date("2026-11-20T11:01:00Z"))
        let snap = c.snapshot()
        XCTAssertEqual(snap["2026-11-20 10"]?["hkObserverWake"], 2)
        XCTAssertEqual(snap["2026-11-20 11"]?["hkObserverWake"], 1)
    }

    func testDurationHelperAddsEventAndMillis() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        let end = date("2026-11-20T10:00:10Z")
        c.note(.writeBack, millis: .writeBackMs, since: end.addingTimeInterval(-2.5), at: end)
        let hour = c.snapshot()["2026-11-20 10"]
        XCTAssertEqual(hour?["writeBack"], 1)
        XCTAssertEqual(hour?["writeBackMs"], 2500)
    }

    func testZeroAmountIsNotRecorded() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkSaveFailed, by: 0)
        XCTAssertTrue(c.snapshot().isEmpty)
    }

    func testFlushPersistsAndNewInstanceReloadsAndMerges() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = date("2026-11-20T10:00:00Z")
        let a = ForkEnergyCounters(fileURL: url, timeZone: utc)
        a.note(.offloadCompleted, by: 3, at: now)
        a.flush(now: now)
        let b = ForkEnergyCounters(fileURL: url, timeZone: utc)
        b.note(.offloadCompleted, at: now)   // noted before the first load, must merge with the file
        XCTAssertEqual(b.snapshot()["2026-11-20 10"]?["offloadCompleted"], 4)
    }

    func testWritesAreThrottled() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = date("2026-11-20T10:00:00Z")
        let c = ForkEnergyCounters(fileURL: url, timeZone: utc)
        c.note(.bgRescore, at: t0)                                  // first note flushes (distantPast)
        c.note(.bgRescore, at: t0.addingTimeInterval(10))           // inside the interval: memory only
        let onDisk = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk?["2026-11-20 10"]?["bgRescore"], 1)
        c.flush(now: t0.addingTimeInterval(11))
        let after = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(after?["2026-11-20 10"]?["bgRescore"], 2)
    }

    func testOldHoursArePruned() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let c = ForkEnergyCounters(fileURL: url, timeZone: utc)
        let start = date("2026-01-01T00:00:00Z")
        for h in 0..<(ForkEnergyCounters.keptHours + 5) {
            c.note(.widgetReload, at: start.addingTimeInterval(Double(h) * 3600))
        }
        c.flush(now: start.addingTimeInterval(1_000_000))
        let onDisk = try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk?.count, ForkEnergyCounters.keptHours)
        XCTAssertNil(onDisk?["2026-01-01 00"])
    }

    func testReportHasDayTotalsAndNoUnknownNames() {
        let c = ForkEnergyCounters(fileURL: nil, timeZone: utc)
        c.note(.hkVitalsWritten, by: 56, at: date("2026-11-20T10:00:00Z"))
        c.note(.hkVitalsWritten, by: 4, at: date("2026-11-20T11:00:00Z"))
        let text = c.report()
        XCTAssertTrue(text.contains("2026-11-20 total: hkVitalsWritten=60"))
        XCTAssertTrue(text.contains("2026-11-20 10h: hkVitalsWritten=56"))
    }

    func testEmptyReport() {
        XCTAssertTrue(ForkEnergyCounters(fileURL: nil, timeZone: utc).report().contains("nothing recorded"))
    }

    // MARK: MetricKit days

    func testMetricKitDayMergeReplacesSameDayAndBounds() {
        var days: [ForkMetricKitDay] = []
        for i in 1...20 {
            days = ForkMetricKitDays.merged(days, with: ForkMetricKitDay(day: String(format: "2026-11-%02d", i), appVersion: nil))
        }
        XCTAssertEqual(days.count, ForkMetricKitDays.keptDays)
        XCTAssertEqual(days.first?.day, "2026-11-07")
        var updated = ForkMetricKitDay(day: "2026-11-20", appVersion: "1")
        updated.cpuSec = 12
        days = ForkMetricKitDays.merged(days, with: updated)
        XCTAssertEqual(days.count, ForkMetricKitDays.keptDays)
        XCTAssertEqual(days.last?.cpuSec, 12)
    }

    func testMetricKitDayRoundTripAndLine() throws {
        var d = ForkMetricKitDay(day: "2026-11-19", appVersion: "2.0.9")
        d.backgroundSec = 12_540; d.cpuSec = 300; d.exits = ["cpuLimit": 1]
        let back = try JSONDecoder().decode(ForkMetricKitDay.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        let line = d.line()
        XCTAssertTrue(line.contains("bg=12540s"))
        XCTAssertTrue(line.contains("exits[cpuLimit=1]"))
        XCTAssertTrue(line.contains("fg=?s"))
    }
}
