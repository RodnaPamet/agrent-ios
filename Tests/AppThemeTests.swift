import SwiftUI
import XCTest
@testable import Agrent

/// «Тема» in Админ (owner, 2026-10-29), and the gold section titles.
final class AppThemeTests: XCTestCase {

    /// Automatic is the phone's own: nothing asked of the window.
    func testEachThemeAsksForItsScheme() {
        XCTAssertNil(AppTheme.automatic.colorScheme)
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
        XCTAssertEqual(AppTheme.allCases.map(\.label), ["Автоматично", "Светла", "Тъмна"])
    }

    /// Stored by raw value: renaming a case would silently drop a choice.
    func testRawValuesArePinned() {
        XCTAssertEqual(AppTheme.allCases.map(\.rawValue), ["automatic", "light", "dark"])
        XCTAssertEqual(AppTheme.storageKey, "appearance.theme")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    /// Applied at the root, so every screen and sheet follows it; and in
    /// Админ above the readers' refusal, so every role can choose.
    func testTheRootAppliesItAndAdminOffersIt() throws {
        XCTAssertTrue(try source("Agrent/AgrentApp.swift").contains(".preferredColorScheme(theme.colorScheme)"))
        let admin = try source("Agrent/Admin/AdminView.swift")
        let row = try XCTUnwrap(admin.range(of: "Section { ThemeRow() }"))
        let refusal = try XCTUnwrap(admin.range(of: "switch store.access"))
        XCTAssertLessThan(row.lowerBound, refusal.lowerBound, "a reader is refused before reaching «Тема»")
    }

    /// The SECTION titles are gold (owner, 2026-10-29: «Разходи», not the
    /// rows under it), through the house views' one token; the cost names
    /// stay in the row's own colour.
    func testSectionTitlesAreGoldNotTheCostNames() throws {
        let chrome = try source("Agrent/Design/FormChrome.swift")
        XCTAssertTrue(chrome.contains("struct SectionHeader"), "positive control: the house header is read")
        let header = try XCTUnwrap(chrome.range(of: "struct SectionHeader"))
        let footer = try XCTUnwrap(chrome.range(of: "struct SectionFooter"))
        XCTAssertTrue(chrome[header.upperBound..<footer.lowerBound].contains("Palette.ListChrome.header"))
        XCTAssertTrue(chrome[footer.upperBound...].contains("Palette.ListChrome.footer"), "footers stay muted")
        // A heading a screen draws itself, in the same gold (owner, 2026-10-31).
        let heading = try XCTUnwrap(chrome.range(of: "struct SectionTitle"))
        let headingEnd = try XCTUnwrap(chrome.range(of: "// MARK:", range: heading.upperBound..<chrome.endIndex))
        XCTAssertTrue(chrome[heading.upperBound..<headingEnd.lowerBound].contains("Palette.ListChrome.header"))

        let calculator = try source("Agrent/Calculator/CalculatorView.swift")
        let row = try XCTUnwrap(calculator.range(of: "struct CostRow"))
        let title = try XCTUnwrap(calculator.range(of: "Text(cost.category.label)", range: row.upperBound..<calculator.endIndex))
        let line = calculator[title.lowerBound...].prefix { $0 != "\n" }
        XCTAssertFalse(line.contains("Palette.accent"), "a cost's name is a row, not a title: \(line)")
    }
}
