import XCTest
@testable import Strand

final class UserDefaultsSetIfChangedTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "UserDefaultsSetIfChangedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// An absent key is written even when the value equals what a read would default to.
    func testAbsentKeyIsWrittenEvenForTheReadDefault() {
        XCTAssertTrue(defaults.setIfChanged(false, forKey: "latch"))
        XCTAssertNotNil(defaults.object(forKey: "latch"))
        XCTAssertTrue(defaults.setIfChanged(0, forKey: "count"))
        XCTAssertTrue(defaults.setIfChanged("", forKey: "text"))
    }

    func testEqualValueIsNotRewritten() {
        defaults.setIfChanged(true, forKey: "b")
        XCTAssertFalse(defaults.setIfChanged(true, forKey: "b"))
        defaults.setIfChanged(42, forKey: "i")
        XCTAssertFalse(defaults.setIfChanged(42, forKey: "i"))
        defaults.setIfChanged(1.5, forKey: "d")
        XCTAssertFalse(defaults.setIfChanged(1.5, forKey: "d"))
        defaults.setIfChanged("x", forKey: "s")
        XCTAssertFalse(defaults.setIfChanged("x", forKey: "s"))
        let blob = Data([1, 2, 3])
        defaults.setIfChanged(blob, forKey: "data")
        XCTAssertFalse(defaults.setIfChanged(blob, forKey: "data"))
    }

    func testDifferentValueIsWrittenAndRead() {
        defaults.setIfChanged(false, forKey: "b")
        XCTAssertTrue(defaults.setIfChanged(true, forKey: "b"))
        XCTAssertTrue(defaults.bool(forKey: "b"))
        defaults.setIfChanged(1, forKey: "i")
        XCTAssertTrue(defaults.setIfChanged(2, forKey: "i"))
        XCTAssertEqual(defaults.integer(forKey: "i"), 2)
        defaults.setIfChanged(Data([1]), forKey: "data")
        XCTAssertTrue(defaults.setIfChanged(Data([2]), forKey: "data"))
        XCTAssertEqual(defaults.data(forKey: "data"), Data([2]))
    }

    /// A stored value of another type is replaced, not treated as equal.
    func testStoredValueOfAnotherTypeIsReplaced() {
        defaults.set("7", forKey: "k")
        XCTAssertTrue(defaults.setIfChanged(7, forKey: "k"))
        XCTAssertEqual(defaults.integer(forKey: "k"), 7)
    }

    /// The latch round trip the battery alerts rely on: set, hold, clear, hold.
    func testLatchSequenceWritesOnlyOnTransitions() {
        let writes = [false, false, true, true, true, false, false].map {
            defaults.setIfChanged($0, forKey: "latch")
        }
        XCTAssertEqual(writes, [true, false, true, false, false, true, false])
    }
}
