import XCTest
@testable import Strand

final class SmartWakeSwipeModelTests: XCTestCase {
    private let w = SmartWakeSwipe.buttonWidth

    func testOpenThresholdIsFortyPercentOfTheButton() {
        XCTAssertFalse(SmartWakeSwipe.settle(reveal: w * 0.4 - 1, projectedDelta: 0, wasOpen: false))
        XCTAssertTrue(SmartWakeSwipe.settle(reveal: w * 0.4, projectedDelta: 0, wasOpen: false))
    }

    func testFlickDecidesRegardlessOfDistance() {
        XCTAssertTrue(SmartWakeSwipe.settle(reveal: 5, projectedDelta: -120, wasOpen: false))
        XCTAssertFalse(SmartWakeSwipe.settle(reveal: w, projectedDelta: 120, wasOpen: true))
    }

    func testOpenRowClosesOnlyAfterBeingDraggedBackFortyPercent() {
        XCTAssertTrue(SmartWakeSwipe.settle(reveal: w * 0.61, projectedDelta: 0, wasOpen: true))
        XCTAssertFalse(SmartWakeSwipe.settle(reveal: w * 0.6, projectedDelta: 0, wasOpen: true))
    }

    func testLiveRevealIsClampedAndRubberBanded() {
        XCTAssertEqual(SmartWakeSwipe.liveReveal(start: 0, translation: 40), 0)          // dragging right when closed
        XCTAssertEqual(SmartWakeSwipe.liveReveal(start: 0, translation: -30), 30)
        XCTAssertEqual(SmartWakeSwipe.liveReveal(start: w, translation: 20), w - 20)
        let far = SmartWakeSwipe.liveReveal(start: 0, translation: -1000)
        XCTAssertEqual(far, w + SmartWakeSwipe.rubberBandLimit)
        XCTAssertEqual(SmartWakeSwipe.liveReveal(start: 0, translation: -1000, rubberBand: false), w)
    }

    func testDirectionLock() {
        XCTAssertTrue(SmartWakeSwipe.isHorizontal(CGSize(width: -20, height: 5)))
        XCTAssertFalse(SmartWakeSwipe.isHorizontal(CGSize(width: 5, height: -20)))
    }

    func testTapOutcomes() {
        let now = Date()
        let other = UUID()
        XCTAssertEqual(SmartWakeSwipe.tap(openID: nil, lastDragActivity: nil, now: now), .edit)
        XCTAssertEqual(SmartWakeSwipe.tap(openID: other, lastDragActivity: nil, now: now), .close)
        XCTAssertEqual(SmartWakeSwipe.tap(openID: nil, lastDragActivity: now.addingTimeInterval(-0.1), now: now), .ignore)
        // the tail of a drag that just opened a row must not close it either
        XCTAssertEqual(SmartWakeSwipe.tap(openID: other, lastDragActivity: now.addingTimeInterval(-0.1), now: now), .ignore)
        XCTAssertEqual(SmartWakeSwipe.tap(openID: nil, lastDragActivity: now.addingTimeInterval(-1), now: now), .edit)
    }
}
