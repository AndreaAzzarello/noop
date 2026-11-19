import XCTest

final class ForkWidgetSnapshotFormatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func full(_ base: ForkWidgetSnapshot) -> ForkWidgetSnapshot {
        base.applyingFullPublish(sleepMin: 420, sleepDay: 5, hrDay: nil, hrFingerprint: "fp",
                                 vitals: nil, sleepStages: nil, workout: nil, trend: nil, extrasKey: "k")
    }

    // MARK: Codable

    func testRoundTripKeepsFormatVersion() throws {
        var snap = ForkWidgetSnapshot(publishedAt: t0)
        snap.formatVersion = ForkWidgetSnapshot.currentFormat
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ForkWidgetSnapshot.self, from: data)
        XCTAssertEqual(back.formatVersion, ForkWidgetSnapshot.currentFormat)
    }

    func testSnapshotWithoutFormatVersionDecodesAsNilAndStaysNil() throws {
        let snap = ForkWidgetSnapshot(publishedAt: t0)
        XCTAssertNil(snap.formatVersion)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ForkWidgetSnapshot.self, from: data)
        XCTAssertNil(back.formatVersion)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["formatVersion"])
        let again = try JSONDecoder().decode(ForkWidgetSnapshot.self, from: JSONEncoder().encode(back))
        XCTAssertNil(again.formatVersion)
    }

    // MARK: Partial writes preserve the version

    func testSmartWakeKeepsExistingVersion() {
        var snap = ForkWidgetSnapshot(publishedAt: t0)
        snap.formatVersion = ForkWidgetSnapshot.currentFormat
        let next = snap.applyingSmartWake(schedule: nil, skipUntil: t0.addingTimeInterval(60))
        XCTAssertEqual(next.formatVersion, ForkWidgetSnapshot.currentFormat)
        XCTAssertEqual(next.smartWakeSkipUntil, t0.addingTimeInterval(60))
    }

    func testSmartWakeNeverInventsAVersion() {
        let snap = ForkWidgetSnapshot(publishedAt: t0)
        XCTAssertNil(snap.applyingSmartWake(schedule: nil, skipUntil: nil).formatVersion)
    }

    func testSmartWakeAfterFullPublishKeepsTheStamp() {
        let stamped = full(ForkWidgetSnapshot(publishedAt: t0))
        XCTAssertEqual(stamped.applyingSmartWake(schedule: nil, skipUntil: nil).formatVersion,
                       ForkWidgetSnapshot.currentFormat)
    }

    // MARK: Full publish stamps and is saved

    func testFullPublishOverUnversionedPreviousStampsAndForcesSaveAndReload() {
        let previous = ForkWidgetSnapshot(publishedAt: t0)
        XCTAssertNil(previous.formatVersion)
        let next = previous.applyingFullPublish(sleepMin: nil, sleepDay: nil, hrDay: nil, hrFingerprint: nil,
                                                vitals: nil, sleepStages: nil, workout: nil, trend: nil,
                                                extrasKey: nil)
        XCTAssertEqual(next.formatVersion, ForkWidgetSnapshot.currentFormat)
        // Everything else equal and fresh: the version alone must still force one save and one reload.
        let d = ForkWidgetSnapshot.commitDecision(next: next, previous: previous, now: t0.addingTimeInterval(60))
        XCTAssertTrue(d.save)
        XCTAssertTrue(d.reload)
    }

    func testSteadyStateWritesNothingAndReloadsNothing() {
        let previous = full(ForkWidgetSnapshot(publishedAt: t0))
        let next = full(previous)
        let d = ForkWidgetSnapshot.commitDecision(next: next, previous: previous, now: t0.addingTimeInterval(60))
        XCTAssertFalse(d.save)
        XCTAssertFalse(d.reload)
    }

    func testOldConfirmationRefreshesWithReload() {
        let previous = full(ForkWidgetSnapshot(publishedAt: t0))
        let later = t0.addingTimeInterval(ForkWidgetSnapshot.republishAfter + 1)
        let d = ForkWidgetSnapshot.commitDecision(next: full(previous), previous: previous, now: later)
        XCTAssertTrue(d.save)
        XCTAssertTrue(d.reload)
    }
}
