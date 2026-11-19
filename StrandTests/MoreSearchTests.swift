import XCTest
@testable import Strand

/// Pins the More tab search index and matcher: accents and case never matter, every More row is reachable,
/// and an empty or unmatched query yields nothing. The matcher is driven with an identity title lookup where
/// the app language would otherwise change the outcome.
final class MoreSearchTests: XCTestCase {

    private func ids(_ query: String) -> [String] {
        MoreSearch.results(for: query, title: { $0.title }).map(\.id)
    }

    // MARK: Normalisation

    func testNormalizeFoldsCaseAccentsAndWhitespace() {
        XCTAssertEqual(MoreSearch.normalize("  SVÉGLIA "), "sveglia")
        XCTAssertEqual(MoreSearch.normalize("Unità"), "unita")
        XCTAssertEqual(MoreSearch.normalize("ＢＡＣＫＵＰ"), "backup", "full-width letters fold too")
    }

    func testIsActiveIgnoresBlankQueries() {
        XCTAssertFalse(MoreSearch.isActive(""))
        XCTAssertFalse(MoreSearch.isActive("  \n "))
        XCTAssertTrue(MoreSearch.isActive(" a "))
    }

    // MARK: Matching

    func testAccentAndCaseVariantsFindTheSameEntries() {
        let base = ids("sveglia")
        XCTAssertTrue(base.contains("more.alarms"))
        XCTAssertEqual(ids("SVEGLIA"), base)
        XCTAssertEqual(ids("Svéglia"), base)
        XCTAssertEqual(ids("  sveglia  "), base)
    }

    func testAccentedKeywordIsFoundWithoutTheAccent() {
        XCTAssertTrue(ids("unita").contains("setting.units"))
        XCTAssertTrue(ids("UNITÀ").contains("setting.units"))
        XCTAssertTrue(ids("funzionalita").contains("setting.features"))
    }

    func testItalianAndEnglishKeywordsReachTheSameScreens() {
        XCTAssertTrue(ids("backup").contains("more.backupSync"))
        XCTAssertTrue(ids("ripristino").contains("more.backupSync"))
        XCTAssertTrue(ids("restore").contains("setting.backupRestore"))
        XCTAssertTrue(ids("batteria").contains("more.powerSaving"))
        XCTAssertTrue(ids("battery").contains("more.powerSaving"))
        XCTAssertTrue(ids("diagnostica").contains("more.testCentre"))
    }

    func testDeepSettingsAreFound() {
        XCTAssertEqual(ids("smart wake").first, "setting.smartWake")
        XCTAssertTrue(ids("sonno leggero").contains("setting.smartWake"))
        XCTAssertTrue(ids("rilevamento allenamenti").contains("setting.autoDetect"))
        XCTAssertTrue(ids("lingua").contains("setting.language"))
        XCTAssertTrue(ids("avvia sessione").contains("setting.liveSessions"))
        XCTAssertTrue(ids("centro test").contains("more.testCentre"))
        XCTAssertTrue(ids("test centre").contains("more.testCentre"))
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(ids("smart zzzz").isEmpty)
        XCTAssertFalse(ids("light sleep").isEmpty)
    }

    func testNoResultsForNonsenseAndForAnEmptyQuery() {
        XCTAssertTrue(ids("qqqqxz").isEmpty)
        XCTAssertTrue(ids("").isEmpty)
        XCTAssertTrue(ids("   ").isEmpty)
    }

    func testTitlePrefixRanksAheadOfTitleContainsAheadOfKeyword() {
        let index = [
            MoreSearch.Entry(id: "k", route: .live, title: "Other", table: .main, parent: "More",
                             symbol: "x", keywords: ["alarm clock"]),
            MoreSearch.Entry(id: "c", route: .live, title: "Smart alarm", table: .main, parent: "More",
                             symbol: "x", keywords: []),
            MoreSearch.Entry(id: "p", route: .live, title: "Alarms", table: .main, parent: "More",
                             symbol: "x", keywords: []),
        ]
        XCTAssertEqual(MoreSearch.results(for: "alarm", in: index, title: { $0.title }).map(\.id), ["p", "c", "k"])
    }

    // MARK: Index

    func testEntryIdsAreUniqueAndKeywordsDoNotRepeatWithinAnEntry() {
        let all = MoreSearch.entries
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate id")
        for entry in all {
            let folded = entry.keywords.map(MoreSearch.normalize)
            XCTAssertEqual(Set(folded).count, folded.count, "repeated keyword in \(entry.id)")
            XCTAssertFalse(folded.contains(where: \.isEmpty), "blank keyword in \(entry.id)")
        }
    }

    func testEveryMoreRouteHasItsOwnRowEntry() {
        for route in MoreSearch.Route.allCases {
            XCTAssertTrue(MoreSearch.entries.contains { $0.id == "more.\(route.rawValue)" && $0.route == route },
                          "no row entry for \(route)")
        }
        XCTAssertEqual(MoreSearch.Route.allCases.count, 27)
    }

    func testTitlesResolveToNonEmptyText() {
        for entry in MoreSearch.entries {
            XCTAssertFalse(MoreSearch.localizedTitle(entry).isEmpty, entry.id)
            XCTAssertFalse(MoreSearch.localizedParent(entry).isEmpty, entry.id)
        }
    }
}
