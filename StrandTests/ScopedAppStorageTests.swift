import SwiftUI
import XCTest
@testable import Strand

@MainActor
final class ScopedAppStorageTests: XCTestCase {

    private let suite = "ScopedAppStorageTests"
    private var store: UserDefaults!

    override func setUp() {
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    func testUnsetKeyReadsTheDefault() {
        let flag = ScopedAppStorage(wrappedValue: true, "flag", store: store)
        let days = ScopedAppStorage(wrappedValue: 14, "days", store: store)
        let raw = ScopedAppStorage(wrappedValue: "", "raw", store: store)
        XCTAssertTrue(flag.wrappedValue)
        XCTAssertEqual(days.wrappedValue, 14)
        XCTAssertEqual(raw.wrappedValue, "")
    }

    func testWriteLandsInTheStoreAndReadsBack() {
        let days = ScopedAppStorage(wrappedValue: 14, "days", store: store)
        days.wrappedValue = 30
        XCTAssertEqual(store.integer(forKey: "days"), 30)
        XCTAssertEqual(days.wrappedValue, 30)
    }

    func testBindingWritesThrough() {
        let raw = ScopedAppStorage(wrappedValue: "", "raw", store: store)
        let binding = raw.projectedValue
        binding.wrappedValue = "a,b"
        XCTAssertEqual(store.string(forKey: "raw"), "a,b")
        XCTAssertEqual(raw.wrappedValue, "a,b")
    }

    func testAnotherWriterIsSeenOnTheNextRead() {
        let flag = ScopedAppStorage(wrappedValue: false, "flag", store: store)
        store.set(true, forKey: "flag")
        XCTAssertTrue(flag.wrappedValue)
    }

    func testAValueOfTheWrongTypeFallsBackToTheDefault() {
        store.set("not a number", forKey: "days")
        let days = ScopedAppStorage(wrappedValue: 14, "days", store: store)
        XCTAssertEqual(days.wrappedValue, 14)
    }
}
