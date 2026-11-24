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

    // MARK: Background reload policy

    private let interval = ForkWidgetSnapshot.backgroundReloadInterval

    /// A confirmed snapshot of today, one minute old, ready to be compared with a changed successor.
    private func base() -> ForkWidgetSnapshot {
        var snap = full(ForkWidgetSnapshot(publishedAt: t0))
        snap.hrDay = ForkHRDay(day: 5, throughTs: 1, minBpm: 50, maxBpm: 90, runs: [])
        return snap
    }

    private func decide(_ next: ForkWidgetSnapshot, _ previous: ForkWidgetSnapshot, after seconds: TimeInterval = 60,
                        background: Bool, lastReload: Date? = nil, owed: Bool = false) -> ForkWidgetSnapshot.CommitDecision {
        ForkWidgetSnapshot.commitDecision(next: next, previous: previous, now: t0.addingTimeInterval(seconds),
                                          background: background, lastReload: lastReload, reloadOwed: owed)
    }

    private func curveMoved(_ snap: ForkWidgetSnapshot) -> ForkWidgetSnapshot {
        var next = snap
        next.hrDay = ForkHRDay(day: 5, throughTs: 2, minBpm: 50, maxBpm: 95, runs: [])
        return next
    }

    func testForegroundContentChangeReloadsAtOnce() {
        let previous = base()
        let d = decide(curveMoved(previous), previous, background: false, lastReload: t0)
        XCTAssertEqual(d, .init(save: true, reload: true, reason: .content, deferred: false))
    }

    func testBackgroundContentChangeInsideTheIntervalIsSavedAndHeldBack() {
        let previous = base()
        let d = decide(curveMoved(previous), previous, background: true, lastReload: t0)
        XCTAssertEqual(d, .init(save: true, reload: false, reason: nil, deferred: true))
    }

    func testBackgroundContentChangePastTheIntervalReloads() {
        let previous = base()
        let d = decide(curveMoved(previous), previous, after: interval, background: true, lastReload: t0)
        XCTAssertEqual(d, .init(save: true, reload: true, reason: .content, deferred: false))
        let before = decide(curveMoved(previous), previous, after: interval - 1, background: true, lastReload: t0)
        XCTAssertFalse(before.reload)
    }

    func testBackgroundWithoutAnyEarlierReloadReloads() {
        let previous = base()
        XCTAssertTrue(decide(curveMoved(previous), previous, background: true, lastReload: nil).reload)
    }

    func testBackgroundClockMovedBackReloads() {
        let previous = base()
        let d = decide(curveMoved(previous), previous, after: 60, background: true, lastReload: t0.addingTimeInterval(3_600))
        XCTAssertTrue(d.reload)
    }

    func testSmartWakeChangeReloadsAtOnceInTheBackground() {
        let previous = base()
        let next = previous.applyingSmartWake(schedule: nil, skipUntil: t0.addingTimeInterval(3_600))
        let d = decide(next, previous, background: true, lastReload: t0)
        XCTAssertEqual(d, .init(save: true, reload: true, reason: .smartWake, deferred: false))
    }

    func testSmartWakeSwitchedOffReloadsAtOnceInTheBackground() {
        var previous = base()
        previous.smartWake = SmartWakeSchedule.standard
        let next = previous.applyingSmartWake(schedule: nil, skipUntil: nil)
        let d = decide(next, previous, background: true, lastReload: t0)
        XCTAssertEqual(d.reason, .smartWake)
        XCTAssertTrue(d.reload)
    }

    func testSmartWakeWinsOverAContentChangeInTheSamePublish() {
        let previous = base()
        let next = curveMoved(previous).applyingSmartWake(schedule: nil, skipUntil: t0.addingTimeInterval(3_600))
        XCTAssertEqual(decide(next, previous, background: true, lastReload: t0).reason, .smartWake)
    }

    func testFirstSnapshotFormatChangeAndDayRollReloadAtOnceInTheBackground() {
        let first = decide(base(), .empty, background: true, lastReload: t0)
        XCTAssertEqual(first.reason, .first)
        XCTAssertTrue(first.reload)

        let previous = base()
        var otherFormat = previous
        otherFormat.formatVersion = ForkWidgetSnapshot.currentFormat + 1
        XCTAssertEqual(decide(otherFormat, previous, background: true, lastReload: t0).reason, .format)

        var tomorrow = previous
        tomorrow.hrDay = ForkHRDay(day: 6, throughTs: 3, minBpm: 50, maxBpm: 90, runs: [])
        XCTAssertEqual(decide(tomorrow, previous, background: true, lastReload: t0).reason, .dayRolled)

        var newSleepDay = previous
        newSleepDay.sleepDay = 6
        XCTAssertEqual(decide(newSleepDay, previous, background: true, lastReload: t0).reason, .dayRolled)
    }

    func testOldConfirmationInTheBackgroundFollowsTheInterval() {
        let previous = base()
        let later = ForkWidgetSnapshot.republishAfter + 1
        XCTAssertEqual(decide(previous, previous, after: later, background: true, lastReload: t0.addingTimeInterval(later - 60)),
                       .init(save: true, reload: false, reason: nil, deferred: true))
        XCTAssertEqual(decide(previous, previous, after: later, background: true, lastReload: t0).reason, .staleRefresh)
    }

    func testOwedReloadIsPaidOnceInTheForegroundEvenWhenNothingChanged() {
        let previous = base()
        let d = decide(previous, previous, background: false, lastReload: t0, owed: true)
        XCTAssertEqual(d, .init(save: false, reload: true, reason: .owed, deferred: false))
    }

    func testOwedReloadIsNotPaidInTheBackground() {
        let previous = base()
        let d = decide(previous, previous, background: true, lastReload: t0, owed: true)
        XCTAssertEqual(d, .init(save: false, reload: false, reason: nil, deferred: false))
    }

    func testForegroundContentChangeWhileOwedReportsContentAndReloadsOnce() {
        let previous = base()
        let d = decide(curveMoved(previous), previous, background: false, lastReload: t0, owed: true)
        XCTAssertEqual(d.reason, .content)
        XCTAssertTrue(d.reload)
    }

    func testUnchangedPayloadNeverSavesOrReloadsInEitherState() {
        let previous = base()
        for background in [false, true] {
            let d = decide(previous, previous, background: background, lastReload: nil)
            XCTAssertEqual(d, .init(save: false, reload: false, reason: nil, deferred: false))
        }
    }

    func testReasonIsSetExactlyWhenReloading() {
        let previous = base()
        for background in [false, true] {
            for next in [previous, curveMoved(previous)] {
                for last in [nil, t0, t0.addingTimeInterval(-10_000)] {
                    let d = decide(next, previous, after: 60, background: background, lastReload: last)
                    XCTAssertEqual(d.reload, d.reason != nil)
                    XCTAssertFalse(d.reload && d.deferred)
                }
            }
        }
    }
}
