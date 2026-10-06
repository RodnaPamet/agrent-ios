import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// The navigation and tab bars are OPAQUE and painted with the tokens
/// `SolidChrome` names — checked on the appearance objects it builds, with
/// the colours resolved per arm, rather than trusted from the code.
@MainActor
final class SolidChromeTests: XCTestCase {
    private static let arms: [(String, UITraitCollection)] = [
        ("dark", UITraitCollection { $0.userInterfaceStyle = .dark }),
        ("light", UITraitCollection { $0.userInterfaceStyle = .light }),
        ("«Слънце»", UITraitCollection {
            $0.userInterfaceStyle = .light
            $0.accessibilityContrast = .high
        }),
    ]

    func testTheNavigationBarIsThePageAndOpaque() {
        let appearance = SolidChrome.navigationAppearance()
        XCTAssertNil(appearance.backgroundEffect, "a blur effect is a material, whatever the colour")
        for (arm, traits) in Self.arms {
            let background = Self.rgba(appearance.backgroundColor, traits)
            XCTAssertEqual(background, Self.rgba(UIColor(Palette.Surface.page), traits), arm)
            XCTAssertEqual(background[3], 1, "\(arm): opaque")
        }
    }

    /// At the scroll edge the bar draws NOTHING — no colour, no blur, no
    /// line — so the page beneath it is the surface. A blur here would be
    /// the material this change removes; an opaque colour hid the large
    /// title on iOS 26 (see `SolidChrome.install()`).
    func testTheScrollEdgeDrawsNothingOfItsOwn() {
        let appearance = SolidChrome.scrollEdgeAppearance()
        XCTAssertNil(appearance.backgroundEffect)
        for (arm, traits) in Self.arms {
            XCTAssertEqual(Self.rgba(appearance.backgroundColor ?? .clear, traits)[3], 0, arm)
            XCTAssertEqual(Self.rgba(appearance.shadowColor ?? .clear, traits)[3], 0, arm)
        }
    }

    func testTheTabBarIsTheBarAndOpaque() {
        let appearance = SolidChrome.tabAppearance()
        XCTAssertNil(appearance.backgroundEffect)
        for (arm, traits) in Self.arms {
            let background = Self.rgba(appearance.backgroundColor, traits)
            XCTAssertEqual(background, Self.rgba(UIColor(Palette.Surface.bar), traits), arm)
            XCTAssertEqual(background[3], 1, "\(arm): opaque")
            let item = appearance.stackedLayoutAppearance
            XCTAssertEqual(Self.rgba(item.normal.iconColor, traits),
                           Self.rgba(UIColor(Palette.secondaryText), traits), "\(arm): unselected tab")
            XCTAssertEqual(Self.rgba(item.selected.iconColor, traits),
                           Self.rgba(UIColor(Palette.accent), traits), "\(arm): selected tab")
        }
    }

    /// Positive control: the colours handed to UIKit stay DYNAMIC through
    /// `UIColor(Color)`. If the bridge flattened them to one arm, the
    /// per-arm equalities above would still hold for that arm and the bar
    /// would stop following the setting — so prove the arms differ.
    func testTheBarColoursFollowTheSetting() {
        let background = SolidChrome.tabAppearance().backgroundColor
        XCTAssertNotEqual(Self.rgba(background, Self.arms[0].1), Self.rgba(background, Self.arms[1].1))
        XCTAssertNotEqual(Self.rgba(background, Self.arms[1].1), Self.rgba(background, Self.arms[2].1))
    }

    func testInstallSetsTheProxies() {
        SolidChrome.install()
        XCTAssertTrue(SolidChrome.isInstalled)
        let page = Self.rgba(UIColor(Palette.Surface.page), Self.arms[0].1)
        XCTAssertEqual(Self.rgba(UINavigationBar.appearance().standardAppearance.backgroundColor,
                                 Self.arms[0].1), page)
        XCTAssertNil(UINavigationBar.appearance().scrollEdgeAppearance?.backgroundEffect)
        XCTAssertNotNil(UINavigationBar.appearance().scrollEdgeAppearance)
        XCTAssertNotNil(UITabBar.appearance().scrollEdgeAppearance)
    }

    private static func rgba(_ color: UIColor?, _ traits: UITraitCollection) -> [Double] {
        guard let color else { return [-1, -1, -1, -1] }  // nil fails every comparison, without trapping
        let resolved = color.resolvedColor(with: traits)
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { (Double($0) * 10_000).rounded() / 10_000 }
    }
}
