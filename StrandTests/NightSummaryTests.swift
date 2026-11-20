import XCTest
@testable import Strand

final class NightSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    private func inputs(total: Double? = 452, eff: Double? = 91, deep: Double? = 80, rem: Double? = 105,
                        light: Double? = 267, smart: NightSummary.NextAlarm? = nil, strap: Date? = nil,
                        early: Date? = nil, need: Int = 480) -> NightSummary.Inputs {
        .init(totalSleepMin: total, efficiency: eff, deepMin: deep, remMin: rem, lightMin: light,
              bedTs: 100, wakeTs: 200, earlyWakeAt: early, smartWake: smart, strapAlarm: strap,
              sleepNeedMinutes: need, now: now)
    }

    // MARK: Recommended bedtime

    func testBedtimeIsLatestWakeMinusNeed() {
        let bedtime = NightSummary.recommendedBedtime(latestWake: at(10), sleepNeedMinutes: 480, now: now)
        XCTAssertEqual(bedtime, at(2))
    }

    func testBedtimeIsNilWithoutAWake() {
        XCTAssertNil(NightSummary.recommendedBedtime(latestWake: nil, sleepNeedMinutes: 480, now: now))
    }

    func testBedtimeThatHasPassedIsNotAdvice() {
        XCTAssertNil(NightSummary.recommendedBedtime(latestWake: at(7), sleepNeedMinutes: 480, now: now))
        XCTAssertNil(NightSummary.recommendedBedtime(latestWake: at(8), sleepNeedMinutes: 480, now: now), "exactly now")
    }

    func testBedtimeAtTheNeedLimits() {
        XCTAssertEqual(NightSummary.recommendedBedtime(latestWake: at(20), sleepNeedMinutes: 300, now: now), at(15))
        XCTAssertEqual(NightSummary.recommendedBedtime(latestWake: at(20), sleepNeedMinutes: 660, now: now), at(9))
    }

    // MARK: Next alarm

    func testSmartWakeWinsOverTheStrapAlarm() {
        let smart = NightSummary.NextAlarm(latest: at(9), windowStart: at(8.5))
        let next = NightSummary.resolveNextAlarm(smartWake: smart, strapAlarm: at(12), now: now)
        XCTAssertEqual(next, smart)
    }

    func testAPastSmartWakeFallsBackToAFutureStrapAlarm() {
        let smart = NightSummary.NextAlarm(latest: at(-1), windowStart: nil)
        let next = NightSummary.resolveNextAlarm(smartWake: smart, strapAlarm: at(5), now: now)
        XCTAssertEqual(next, NightSummary.NextAlarm(latest: at(5), windowStart: nil))
    }

    func testNoFutureAlarmMeansNoNextAlarm() {
        XCTAssertNil(NightSummary.resolveNextAlarm(smartWake: nil, strapAlarm: nil, now: now))
        XCTAssertNil(NightSummary.resolveNextAlarm(smartWake: nil, strapAlarm: at(-2), now: now))
    }

    // MARK: Assembly

    func testFullNight() {
        let s = NightSummary.make(inputs(smart: .init(latest: at(14), windowStart: nil), early: at(-1)))
        XCTAssertEqual(s.sleepMinutes, 452)
        XCTAssertEqual(s.efficiencyPct, 91)
        XCTAssertEqual(s.stages, NightSummary.Stages(deepMin: 80, remMin: 105, lightMin: 267))
        XCTAssertEqual(s.earlyWakeAt, at(-1))
        XCTAssertEqual(s.bedtime, at(6))
        XCTAssertTrue(s.hasSleep)
    }

    func testNoSleepDropsEveryNightFigureButKeepsTheAlarmLines() {
        let s = NightSummary.make(inputs(total: nil, smart: .init(latest: at(14), windowStart: nil), early: at(-1)))
        XCTAssertFalse(s.hasSleep)
        XCTAssertNil(s.stages)
        XCTAssertNil(s.efficiencyPct)
        XCTAssertNil(s.earlyWakeAt)
        XCTAssertNil(s.bedTs)
        XCTAssertNotNil(s.nextAlarm)
        XCTAssertNotNil(s.bedtime)
    }

    func testZeroStagesAndOutOfRangeEfficiencyAreNotStated() {
        let s = NightSummary.make(inputs(eff: 140, deep: 0, rem: nil, light: 0))
        XCTAssertNil(s.stages)
        XCTAssertNil(s.efficiencyPct)
        XCTAssertNil(s.stageShares)
    }

    func testNonFiniteDurationIsNotStated() {
        XCTAssertNil(NightSummary.make(inputs(total: .nan)).sleepMinutes)
        XCTAssertNil(NightSummary.make(inputs(total: 0)).sleepMinutes)
    }

    func testStageSharesSumToOneInBarOrder() throws {
        let shares = try XCTUnwrap(NightSummary.make(inputs(deep: 60, rem: 120, light: 180)).stageShares)
        XCTAssertEqual(shares.map(\.stage), ["deep", "rem", "light"])
        XCTAssertEqual(shares.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(shares[0].fraction, 60.0 / 360.0, accuracy: 1e-12)
    }

    // MARK: Read-only skip peek

    func testSkipPeekReadsWithoutDeleting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NightSkipPeekTests"))
        defer { defaults.removePersistentDomain(forName: "NightSkipPeekTests") }
        let spent = now.addingTimeInterval(-60).timeIntervalSince1970
        defaults.set(spent, forKey: SmartWakeFirmwareSkip.key)
        XCTAssertEqual(NightSkipPeek.searchStart(now: now, smartWakeEnabled: true, defaults: defaults), now)
        XCTAssertNotNil(defaults.object(forKey: SmartWakeFirmwareSkip.key), "a spent value must stay in the store")

        let live = now.addingTimeInterval(3600)
        defaults.set(live.timeIntervalSince1970, forKey: SmartWakeFirmwareSkip.key)
        XCTAssertEqual(NightSkipPeek.searchStart(now: now, smartWakeEnabled: true, defaults: defaults), live)
        XCTAssertEqual(NightSkipPeek.searchStart(now: now, smartWakeEnabled: false, defaults: defaults), now)

        defaults.set(now.addingTimeInterval(48 * 3600).timeIntervalSince1970, forKey: SmartWakeFirmwareSkip.key)
        XCTAssertEqual(NightSkipPeek.searchStart(now: now, smartWakeEnabled: true, defaults: defaults), now,
                       "more than 24 h ahead is not something a morning could have recorded")
    }
}

final class SmartWakeEarlyWakeRecordTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "SmartWakeEarlyWakeRecordTests")
        defaults.removePersistentDomain(forName: "SmartWakeEarlyWakeRecordTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SmartWakeEarlyWakeRecordTests")
    }

    func testRecordInsideTheNightIsReturned() {
        SmartWakeEarlyWakeRecord.record(at: Date(timeIntervalSince1970: 5_000), defaults: defaults)
        XCTAssertEqual(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: 5_100, defaults: defaults),
                       Date(timeIntervalSince1970: 5_000))
    }

    func testRecordJustAfterWakeWithinGraceIsReturned() {
        SmartWakeEarlyWakeRecord.record(at: Date(timeIntervalSince1970: 5_000 + 1_800), defaults: defaults)
        XCTAssertNotNil(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: 5_000, defaults: defaults))
        SmartWakeEarlyWakeRecord.record(at: Date(timeIntervalSince1970: 5_000 + 1_801), defaults: defaults)
        XCTAssertNil(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: 5_000, defaults: defaults))
    }

    func testRecordFromAnotherNightIsNotStated() {
        SmartWakeEarlyWakeRecord.record(at: Date(timeIntervalSince1970: 500), defaults: defaults)
        XCTAssertNil(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: 5_000, defaults: defaults))
    }

    func testNoNightOrNoRecordMeansNothing() {
        XCTAssertNil(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: 5_000, defaults: defaults))
        SmartWakeEarlyWakeRecord.record(at: Date(timeIntervalSince1970: 2_000), defaults: defaults)
        XCTAssertNil(SmartWakeEarlyWakeRecord.firedAt(inNight: nil, wakeTs: 5_000, defaults: defaults))
        XCTAssertNil(SmartWakeEarlyWakeRecord.firedAt(inNight: 1_000, wakeTs: nil, defaults: defaults))
    }
}
