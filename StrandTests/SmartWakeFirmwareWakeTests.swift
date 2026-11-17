import XCTest
@testable import Strand

final class SmartWakeFirmwareWakeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SmartWakeFirmwareWakeTests")!
        defaults.removePersistentDomain(forName: "SmartWakeFirmwareWakeTests")
    }

    func testNothingStoredMeansNoOverride() {
        var armed: [Date] = []
        XCTAssertFalse(SmartWakeFirmwareWake.holdsAlarm(now: now, defaults: defaults) { armed.append($0) })
        XCTAssertTrue(armed.isEmpty)
    }

    func testFutureInstantIsHeldAndReSent() {
        let fire = now.addingTimeInterval(30)
        SmartWakeFirmwareWake.set(fire, defaults: defaults)
        var armed: [Date] = []
        XCTAssertTrue(SmartWakeFirmwareWake.holdsAlarm(now: now, defaults: defaults) { armed.append($0) })
        XCTAssertEqual(armed, [fire])
    }

    func testJustPassedInstantIsHeldButNotReArmedInThePast() {
        SmartWakeFirmwareWake.set(now.addingTimeInterval(-10), defaults: defaults)
        var armed: [Date] = []
        XCTAssertTrue(SmartWakeFirmwareWake.holdsAlarm(now: now, defaults: defaults) { armed.append($0) })
        XCTAssertTrue(armed.isEmpty)
    }

    func testStaleInstantIsRemovedAndNeverBlocksTheNormalAlarm() {
        SmartWakeFirmwareWake.set(now.addingTimeInterval(-SmartWakeFirmwareWake.staleAfter - 1), defaults: defaults)
        XCTAssertFalse(SmartWakeFirmwareWake.holdsAlarm(now: now, defaults: defaults) { _ in XCTFail() })
        XCTAssertNil(defaults.object(forKey: SmartWakeFirmwareWake.key))
    }

    func testImplausiblyFarInstantIsRemoved() {
        SmartWakeFirmwareWake.set(now.addingTimeInterval(SmartWakeFirmwareWake.maximumAhead + 1), defaults: defaults)
        XCTAssertNil(SmartWakeFirmwareWake.current(now: now, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: SmartWakeFirmwareWake.key))
    }

    func testClearRemovesTheOverride() {
        SmartWakeFirmwareWake.set(now.addingTimeInterval(30), defaults: defaults)
        SmartWakeFirmwareWake.clear(defaults: defaults)
        XCTAssertNil(SmartWakeFirmwareWake.current(now: now, defaults: defaults))
    }

    // MARK: iPhone backup date

    func testBackupIsFiveMinutesAfterTheEarlyWake() {
        let max = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(SmartWakeBackupPlan.backupDate(earlyAt: now, maximumWakeTime: max), now.addingTimeInterval(300))
    }

    func testNoBackupWhenItWouldNotBeBeforeTheMaximumTime() {
        XCTAssertNil(SmartWakeBackupPlan.backupDate(earlyAt: now, maximumWakeTime: now.addingTimeInterval(300)))
        XCTAssertNil(SmartWakeBackupPlan.backupDate(earlyAt: now, maximumWakeTime: now.addingTimeInterval(120)))
        XCTAssertNotNil(SmartWakeBackupPlan.backupDate(earlyAt: now, maximumWakeTime: now.addingTimeInterval(301)))
    }
}
