import XCTest
@testable import HopCore

private struct W { let app: String; let title: String }

private func ranked(_ items: [W], _ query: String) -> [String] {
    Matcher.rank(items, query: query) { ($0.app, $0.title) }.map { "\($0.app)|\($0.title)" }
}

final class MatcherTests: XCTestCase {
    func testAppPrefixBeatsCrossFieldAcronym() {
        // Safari·Login is more recent, but "sl" should still prefer Slack.
        let items = [W(app: "Safari", title: "Login"), W(app: "Slack", title: "general")]
        XCTAssertEqual(ranked(items, "sl").first, "Slack|general")
    }

    func testCrossFieldAcronymStillMatches() {
        let items = [W(app: "Safari", title: "Login"), W(app: "Notes", title: "Groceries")]
        XCTAssertEqual(ranked(items, "sl"), ["Safari|Login"])
    }

    func testAppAcronym() {
        let items = [W(app: "Finder", title: "vsc-notes"), W(app: "Visual Studio Code", title: "main.swift")]
        XCTAssertEqual(ranked(items, "vsc").first, "Visual Studio Code|main.swift")
    }

    func testPrefixBeatsMidWord() {
        let items = [W(app: "Notes", title: "intermediate"), W(app: "Terminal", title: "zsh")]
        XCTAssertEqual(ranked(items, "term"), ["Terminal|zsh", "Notes|intermediate"])
    }

    func testTitleWordMatch() {
        let items = [W(app: "Safari", title: "Apple Developer Documentation"), W(app: "Mail", title: "Inbox")]
        XCTAssertEqual(ranked(items, "dev").first, "Safari|Apple Developer Documentation")
    }

    func testEmptyQueryKeepsRecencyOrder() {
        let items = [W(app: "B", title: "2"), W(app: "A", title: "1"), W(app: "C", title: "3")]
        XCTAssertEqual(ranked(items, ""), ["B|2", "A|1", "C|3"])
        XCTAssertEqual(ranked(items, "   "), ["B|2", "A|1", "C|3"])
    }

    func testTiesBrokenByRecency() {
        let items = [W(app: "Safari", title: "One"), W(app: "Safari", title: "Two")]
        XCTAssertEqual(ranked(items, "saf"), ["Safari|One", "Safari|Two"])
    }

    func testNonMatchIsDropped() {
        XCTAssertNil(Matcher.score(query: "xyz", appName: "Slack", title: "general"))
        XCTAssertNil(Matcher.score(query: "slackk", appName: "Slack", title: ""))
    }

    func testCaseInsensitiveAndSpacesIgnored() {
        XCTAssertNotNil(Matcher.score(query: "SAF log", appName: "Safari", title: "Login"))
    }

    func testCamelCaseBoundaries() {
        XCTAssertEqual(Matcher.initials(Array("iTerm2")), "it2")
        XCTAssertEqual(Matcher.initials(Array("Safari · Login")), "sl")
    }

    func testMidWordSubstringMatches() {
        XCTAssertNotNil(Matcher.fuzzyScore(Array("code"), Array("Xcode")))
        XCTAssertNotNil(Matcher.score(query: "book", appName: "Safari", title: "Facebook"))
    }

    func testScatteredLettersDoNotMatch() {
        XCTAssertNil(Matcher.fuzzyScore(Array("code"), Array("Chocolade")))
        // Regression: "finder" used to match f·i…n·d…e·r spread across this Chrome title.
        XCTAssertNil(Matcher.score(query: "finder", appName: "Google Chrome",
                                   title: "Panehop, the search-first window switcher for macOS - Google Chrome - James"))
        let items = [W(app: "Google Chrome", title: "Panehop, the search-first window switcher for macOS"),
                     W(app: "Finder", title: "Chrome Apps")]
        XCTAssertEqual(ranked(items, "finder"), ["Finder|Chrome Apps"])
    }

    func testWordStartChunksMatch() {
        XCTAssertNotNil(Matcher.score(query: "goch", appName: "Google Chrome", title: ""))
        XCTAssertNotNil(Matcher.score(query: "chrapp", appName: "Finder", title: "Chrome Apps"))
    }

    func testBoundaryMatchBeatsMidWordSubstring() {
        let items = [W(app: "Notes", title: "Barcode"), W(app: "Notes", title: "Code review")]
        XCTAssertEqual(ranked(items, "code"), ["Notes|Code review", "Notes|Barcode"])
    }
}
