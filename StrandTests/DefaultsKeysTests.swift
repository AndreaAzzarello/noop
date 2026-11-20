import XCTest
import Combine
@testable import Strand

@MainActor
final class DefaultsKeysTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName = ""
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        suiteName = "DefaultsKeysTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        bag.removeAll()
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    private func count(_ k: DefaultsKeys) -> () -> Int {
        var n = 0
        k.objectWillChange.sink { n += 1 }.store(in: &bag)
        return { n }
    }

    func testForeignKeyDoesNotPublish() {
        let k = DefaultsKeys(["own.a"], defaults: suite)
        let n = count(k)
        suite.set(1, forKey: "foreign")
        suite.set(2, forKey: "foreign")
        XCTAssertEqual(n(), 0)
    }

    func testOwnKeyNewValuePublishesOnce() {
        let k = DefaultsKeys(["own.a"], defaults: suite)
        let n = count(k)
        suite.set("x", forKey: "own.a")
        XCTAssertEqual(n(), 1)
        XCTAssertEqual(k.string("own.a", default: ""), "x")
    }

    func testOwnKeyEqualValueDoesNotPublish() {
        suite.set(true, forKey: "own.b")
        let k = DefaultsKeys(["own.b"], defaults: suite)
        let n = count(k)
        suite.set(true, forKey: "own.b")
        XCTAssertEqual(n(), 0)
    }

    func testRemoveOwnKeyPublishes() {
        suite.set("x", forKey: "own.a")
        let k = DefaultsKeys(["own.a"], defaults: suite)
        let n = count(k)
        suite.removeObject(forKey: "own.a")
        XCTAssertEqual(n(), 1)
        XCTAssertEqual(k.string("own.a", default: "d"), "d")
    }

    func testSetPersistsAndPublishesOnce() {
        let k = DefaultsKeys(["own.a"], defaults: suite)
        let n = count(k)
        k.set("v", forKey: "own.a")
        XCTAssertEqual(suite.string(forKey: "own.a"), "v")
        XCTAssertEqual(n(), 1)
    }

    func testAbsentKeyYieldsDefault() {
        let k = DefaultsKeys(["own.a", "own.b"], defaults: suite)
        XCTAssertEqual(k.string("own.a", default: "dflt"), "dflt")
        XCTAssertTrue(k.bool("own.b", default: true))
        XCTAssertFalse(k.bool("own.b", default: false))
    }

    func testBackgroundWritePublishesOnMain() {
        let k = DefaultsKeys(["own.a"], defaults: suite)
        let published = expectation(description: "published on main")
        k.objectWillChange.sink {
            XCTAssertTrue(Thread.isMainThread)
            published.fulfill()
        }.store(in: &bag)
        let suite = self.suite!
        DispatchQueue.global().async { suite.set("bg", forKey: "own.a") }
        wait(for: [published], timeout: 2)
    }
}
