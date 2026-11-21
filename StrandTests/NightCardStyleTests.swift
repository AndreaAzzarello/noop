import XCTest
@testable import Strand

/// A night that reaches the card late still gets the full card; one seen in the morning goes compact after noon.
final class NightCardStyleTests: XCTestCase {
    typealias S = NightCardStyle
    private let day = "2026-11-21"
    private let morning = Date(timeIntervalSince1970: 1_800_000_000)
    private var afternoon: Date { morning.addingTimeInterval(6 * 3600) }

    func testNoNightYetKeepsTheRequestedStyle() {
        XCTAssertEqual(S.resolve(requested: .compact, hasSleep: false, nightDay: day, seen: nil, now: afternoon).style, .compact)
        XCTAssertEqual(S.resolve(requested: .full, hasSleep: false, nightDay: nil, seen: nil, now: morning).style, .full)
        XCTAssertNil(S.resolve(requested: .compact, hasSleep: false, nightDay: day, seen: nil, now: afternoon).record)
    }

    func testANightSeenInTheMorningGoesCompactAfterNoon() {
        let first = S.resolve(requested: .full, hasSleep: true, nightDay: day, seen: nil, now: morning)
        XCTAssertEqual(first.style, .full)
        let seen = try! XCTUnwrap(first.record)
        XCTAssertEqual(S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: seen, now: afternoon).style, .compact)
    }

    func testALateArrivalGetsTheFullCardForTheGraceThenCompact() {
        // The night is processed at 11:00 but the card first sees it after noon.
        let first = S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: nil, now: afternoon)
        XCTAssertEqual(first.style, .full, "news is full whatever the hour")
        let seen = try! XCTUnwrap(first.record)
        XCTAssertEqual(seen, S.Seen(nightDay: day, firstSeenAt: afternoon))
        // A later reload (a refresh bumped the key) must not collapse it at once.
        let soon = afternoon.addingTimeInterval(30 * 60)
        XCTAssertEqual(S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: seen, now: soon).style, .full)
        XCTAssertNil(S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: seen, now: soon).record)
        let later = afternoon.addingTimeInterval(S.lateArrivalGrace)
        XCTAssertEqual(S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: seen, now: later).style, .compact)
    }

    func testANewNightIsNewsEvenAfterAnOldRecord() {
        let old = S.Seen(nightDay: "2026-11-20", firstSeenAt: morning.addingTimeInterval(-86_400))
        let r = S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: old, now: afternoon)
        XCTAssertEqual(r.style, .full)
        XCTAssertEqual(r.record?.nightDay, day)
    }

    func testAClockSetBackDoesNotKeepItFullForever() {
        let seen = S.Seen(nightDay: day, firstSeenAt: afternoon)
        XCTAssertEqual(S.resolve(requested: .compact, hasSleep: true, nightDay: day, seen: seen,
                                 now: afternoon.addingTimeInterval(-3600)).style, .compact)
    }

    func testTheFullStyleStaysFullWhateverTheRecord() {
        let seen = S.Seen(nightDay: day, firstSeenAt: morning.addingTimeInterval(-9 * 3600))
        XCTAssertEqual(S.resolve(requested: .full, hasSleep: true, nightDay: day, seen: seen, now: morning).style, .full)
    }
}
