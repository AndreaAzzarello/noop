import XCTest
@testable import Strand

/// A completed offload republishes the widget only when something new reached the store, or when the alarm list, the
/// next alarm or a low strap battery changed. Those three keep updating at once, in the background too.
final class OffloadWidgetPublishGateTests: XCTestCase {
    typealias Gate = OffloadWidgetPublishGate
    private let base = Gate.State(batteryPct: 80, nextAlarmTs: 1_800_030_000, alarmListRevision: 4)

    func testTheFirstPublishAfterLaunchGoesOut() {
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: nil, now: base), .firstPublish)
    }

    func testAnOffloadWithNothingNewIsSkipped() {
        XCTAssertNil(Gate.reason(newDataBanked: false, last: base, now: base))
    }

    func testAnOffloadThatBankedDataPublishes() {
        XCTAssertEqual(Gate.reason(newDataBanked: true, last: base, now: base), .newData)
    }

    func testAChangedAlarmListPublishesWithoutNewData() {
        var now = base; now.alarmListRevision = 5
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: base, now: now), .alarmListChanged)
    }

    func testAChangedNextAlarmPublishesWithoutNewData() {
        var now = base; now.nextAlarmTs = 1_800_116_400 // the alarm rang, tomorrow's is next
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: base, now: now), .nextAlarmChanged)
        now.nextAlarmTs = nil // the last alarm was switched off
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: base, now: now), .nextAlarmChanged)
    }

    func testALowBatteryPublishesWithoutNewData() {
        var now = base; now.batteryPct = 15
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: base, now: now), .lowBattery)
        var last = base; last.batteryPct = 15
        now.batteryPct = 14
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: last, now: now), .lowBattery, "every step under the line")
    }

    func testRecoveringAboveTheLineClearsTheLowState() {
        var last = base; last.batteryPct = 12
        var now = base; now.batteryPct = 30
        XCTAssertEqual(Gate.reason(newDataBanked: false, last: last, now: now), .lowBattery)
    }

    func testABatteryChangeAboveTheLineIsNotNews() {
        var now = base; now.batteryPct = 79
        XCTAssertNil(Gate.reason(newDataBanked: false, last: base, now: now))
        now.batteryPct = nil
        XCTAssertNil(Gate.reason(newDataBanked: false, last: base, now: now))
    }

    func testAnUnchangedLowBatteryIsNotRepublished() {
        var low = base; low.batteryPct = 10
        XCTAssertNil(Gate.reason(newDataBanked: false, last: low, now: low))
    }
}
