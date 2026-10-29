import SwiftUI
import XCTest
@testable import Agrent

/// «Тема» in Админ (owner, 2026-10-29), and the gold cost titles.
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

    /// The cost list's titles are gold, as the crop names are.
    func testCostTitlesAreGold() throws {
        let calculator = try source("Agrent/Calculator/CalculatorView.swift")
        let row = try XCTUnwrap(calculator.range(of: "struct CostRow"))
        let title = try XCTUnwrap(calculator.range(of: "Text(cost.category.label)", range: row.upperBound..<calculator.endIndex))
        let gold = try XCTUnwrap(calculator.range(of: ".foregroundStyle(Palette.accent)", range: title.upperBound..<calculator.endIndex))
        XCTAssertLessThan(calculator.distance(from: title.upperBound, to: gold.lowerBound), 120)
    }
}
