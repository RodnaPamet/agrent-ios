import CoreText
import UIKit
import XCTest
@testable import Agrent

/// Bulgarian letterforms on every screen, on every phone (#205; owner,
/// 2026-10-08). Two halves: SwiftUI's text through `.typesettingLanguage` at
/// the root, and the bars UIKit draws through a CoreText language attribute.
/// Without either, a phone that lists no Bulgarian mixes the two shapes.
@MainActor
final class BulgarianLetterformTests: XCTestCase {

    private let language = NSAttributedString.Key(kCTLanguageAttributeName as String)

    /// Every bar title and tab label: the attribute CoreText picks the shapes
    /// from, and the colour the tab labels already had, both kept.
    func testBarTitlesAndTabLabelsAreSetInBulgarian() {
        for appearance in [SolidChrome.navigationAppearance(), SolidChrome.scrollEdgeAppearance()] {
            XCTAssertEqual(appearance.titleTextAttributes[language] as? String, "bg")
            XCTAssertEqual(appearance.largeTitleTextAttributes[language] as? String, "bg")
        }
        let tabs = SolidChrome.tabAppearance()
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance,
                     tabs.compactInlineLayoutAppearance] {
            XCTAssertEqual(item.normal.titleTextAttributes[language] as? String, "bg")
            XCTAssertEqual(item.selected.titleTextAttributes[language] as? String, "bg")
            XCTAssertNotNil(item.normal.titleTextAttributes[.foregroundColor],
                            "the label's colour was lost in the merge")
            XCTAssertNotNil(item.selected.titleTextAttributes[.foregroundColor],
                            "the label's colour was lost in the merge")
        }
    }

    /// The root sets it for SwiftUI's text, sheets included. Read from the
    /// source: the environment value it sets has no public reader to probe.
    func testTheRootTypesetsInBulgarian() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/AgrentApp.swift")
        let app = SignOutHygieneTests.code(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(app.contains(#".environment(\.locale, Locale(identifier: "bg_BG"))"#),
                      "positive control: the root's modifiers moved")
        XCTAssertTrue(app.contains(#".typesettingLanguage(Locale.Language(identifier: "bg"))"#),
                      "the root no longer typesets in Bulgarian")
    }

    // MARK: - The app's own language list

    func testBulgarianLeadsTheList() {
        XCTAssertEqual(BulgarianLetterforms.preferringBulgarian(["en-US"]), ["bg", "en-US"])
        XCTAssertEqual(BulgarianLetterforms.preferringBulgarian([]), ["bg"])
        XCTAssertEqual(BulgarianLetterforms.preferringBulgarian(["en-BG", "bg-BG"]), ["bg", "en-BG"],
                       "a Bulgarian entry further down moves to the front, once")
        XCTAssertEqual(BulgarianLetterforms.preferringBulgarian(["bg-BG", "en"]), ["bg-BG", "en"],
                       "a list already led by Bulgarian is left alone")
        XCTAssertEqual(BulgarianLetterforms.preferringBulgarian(["bgc", "en"]), ["bg", "bgc", "en"],
                       "only `bg` is Bulgarian, not every code that starts with the letters")
    }

    func testInstallWritesOnceAndOnlyWhenNeeded() throws {
        let suite = "test.letterforms.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["en-US"], forKey: BulgarianLetterforms.key)
        BulgarianLetterforms.install(defaults)
        XCTAssertEqual(defaults.stringArray(forKey: BulgarianLetterforms.key), ["bg", "en-US"])
        BulgarianLetterforms.install(defaults)
        XCTAssertEqual(defaults.stringArray(forKey: BulgarianLetterforms.key), ["bg", "en-US"],
                       "a second launch must not stack another `bg`")
    }

    /// Wired: the test host IS the app, so `AgrentApp.init` has run, and the
    /// app's own list leads with Bulgarian, whatever this simulator lists.
    func testTheAppsOwnListLeadsWithBulgarian() {
        let first = UserDefaults.standard.stringArray(forKey: BulgarianLetterforms.key)?.first ?? ""
        XCTAssertTrue(first == "bg" || first.hasPrefix("bg-"), "the app's list starts with \(first)")
    }

    /// First in `init`, ahead of `BulgarianLayout`, whose priming should
    /// measure the shapes the app will draw.
    func testItRunsBeforeTheLayoutPriming() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Agrent/AgrentApp.swift")
        let app = SignOutHygieneTests.code(try String(contentsOf: url, encoding: .utf8))
        let letterforms = try XCTUnwrap(app.range(of: "BulgarianLetterforms.install()"))
        let layout = try XCTUnwrap(app.range(of: "BulgarianLayout.install()"), "positive control")
        XCTAssertLessThan(letterforms.lowerBound, layout.lowerBound)
    }
}
