import SwiftUI
import UIKit
import XCTest
@testable import Agrent

/// Every ratio `Palette.swift` documents, recomputed from the colours as the
/// app RESOLVES them — through `Color(token:)`'s dynamic provider and the
/// same trait collections the system hands it — rather than from the hex
/// values in a comment. A comment can go stale; this cannot.
final class PaletteTokenTests: XCTestCase {
    /// The four settings combinations, and the arm each one must land on.
    private static let dark = UITraitCollection { $0.userInterfaceStyle = .dark }
    private static let light = UITraitCollection { $0.userInterfaceStyle = .light }
    private static let sunlight = UITraitCollection {
        $0.userInterfaceStyle = .light
        $0.accessibilityContrast = .high
    }
    private static let darkIncreased = UITraitCollection {
        $0.userInterfaceStyle = .dark
        $0.accessibilityContrast = .high
    }

    // MARK: - Which arm

    func testTheSettingsChooseTheDocumentedArm() {
        XCTAssertEqual(AgrentTheme.current(Self.dark), .dark)
        XCTAssertEqual(AgrentTheme.current(Self.light), .light)
        XCTAssertEqual(AgrentTheme.current(Self.sunlight), .highContrast)
        // «Слънце» is a light palette; dark mode keeps the dark arm.
        XCTAssertEqual(AgrentTheme.current(Self.darkIncreased), .dark)
        XCTAssertEqual(AgrentTheme.current(UITraitCollection()), .light, "unspecified reads as light")
    }

    /// The resolved page IS the token, arm by arm — the bridge picks the
    /// value rather than merely some value.
    func testTheBridgeResolvesToTheTokenItWasGiven() {
        for (traits, theme) in [(Self.dark, AgrentTheme.dark), (Self.light, .light),
                                (Self.sunlight, .highContrast), (Self.darkIncreased, .dark)] {
            XCTAssertEqual(Self.rgba(Palette.Surface.page, traits), Self.rgba(AgrentColor.bgPage(theme), traits),
                           "\(theme)")
        }
        XCTAssertNotEqual(Self.rgba(Palette.Surface.page, Self.light), Self.rgba(Palette.Surface.page, Self.sunlight),
                          "positive control: light and «Слънце» pages differ, so the comparison above can fail")
    }

    // MARK: - The ratios Palette.swift documents

    /// (role, ink, fill, documented dark / light / «Слънце»). Fills are
    /// composited over the page, inks over the fill, as on screen.
    private static let pairs: [(String, Color, Color, [Double])] = [
        ("accent on page", Palette.accent, Palette.Surface.page, [7.91, 4.90, 5.49]),
        ("accentDeep on page", Palette.accentDeep, Palette.Surface.page, [5.11, 5.82, 6.51]),
        ("onAccent on accent", Palette.onAccent, Palette.accent, [8.45, 5.21, 5.21]),
        ("onAccent on accentDeep", Palette.onAccent, Palette.accentDeep, [5.46, 6.19, 6.19]),
        ("error on page", Palette.error, Palette.Surface.page, [7.26, 7.57, 7.75]),
        ("onError on error", Palette.onError, Palette.error, [7.76, 8.05, 7.37]),
        ("success on page", Palette.success, Palette.Surface.page, [10.25, 6.59, 8.08]),
        ("warning on page", Palette.warning, Palette.Surface.page, [9.96, 6.24, 7.13]),
        ("secondaryText on page", Palette.secondaryText, Palette.Surface.page, [9.17, 6.98, 11.37]),
        ("input chip", Palette.Chip.inputText, Palette.Chip.inputFill, [7.33, 5.29, 5.83]),
        ("activity chip", Palette.Chip.activityText, Palette.Chip.activityFill, [6.53, 6.79, 7.43]),
        ("neutral chip", Palette.Chip.neutralText, Palette.Chip.neutralFill, [7.48, 6.51, 10.43]),
        ("avatar", Palette.Avatar.ink, Palette.Avatar.fill, [8.45, 5.21, 6.19]),
    ]

    func testEveryDocumentedPairMeasuresWhatItSaysAndPassesAA() {
        for (name, ink, fill, documented) in Self.pairs {
            for (traits, arm, expected) in zip3([Self.dark, Self.light, Self.sunlight],
                                                ["dark", "light", "«Слънце»"], documented) {
                let ratio = Self.contrast(ink, on: fill, traits)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name), \(arm): \(ratio)")
                XCTAssertEqual(ratio, expected, accuracy: 0.02,
                               "\(name), \(arm): Palette.swift says \(expected), measured \(ratio)")
            }
        }
    }

    /// Positive control for the measurement itself: white on black is 21:1,
    /// and the web's `brand` badge pair (`--brand-muted` on `--brand-subtle`),
    /// which `Chip.inputText` declines in light, measures the 1.71 its
    /// comment cites. If this passed for a broken `contrast`, the ≥ 4.5
    /// assertions above would prove nothing.
    func testTheMeasurementCanFail() {
        XCTAssertEqual(Self.contrast(Color(hex: 0xFFFFFF), on: Color(hex: 0x000000), Self.light), 21, accuracy: 0.01)
        let rejected = Self.contrast(Color(token: AgrentColor.brandMuted), on: Palette.Chip.inputFill, Self.light)
        XCTAssertEqual(rejected, 1.71, accuracy: 0.02)
        XCTAssertLessThan(rejected, 4.5)
    }

    /// Increase Contrast must RAISE the avatar's ratio in light, not just
    /// change the colour.
    func testIncreaseContrastRaisesTheAvatar() {
        XCTAssertGreaterThan(Self.contrast(Palette.Avatar.ink, on: Palette.Avatar.fill, Self.sunlight),
                             Self.contrast(Palette.Avatar.ink, on: Palette.Avatar.fill, Self.light))
    }

    // MARK: - helpers

    private static func rgba(_ color: Color, _ traits: UITraitCollection) -> [Double] {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { (Double($0) * 10_000).rounded() / 10_000 }
    }

    private static func over(_ top: [Double], _ bottom: [Double]) -> [Double] {
        (0..<3).map { top[$0] * top[3] + bottom[$0] * (1 - top[3]) } + [1]
    }

    /// WCAG 2.x contrast of `ink` over `fill`, the fill composited over the
    /// page first — a translucent chip fill has no colour of its own.
    private static func contrast(_ ink: Color, on fill: Color, _ traits: UITraitCollection) -> Double {
        let background = over(rgba(fill, traits), rgba(Palette.Surface.page, traits))
        let foreground = over(rgba(ink, traits), background)
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: [Double]) -> Double {
            0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
        }
        let (hi, lo) = (max(luminance(foreground), luminance(background)),
                        min(luminance(foreground), luminance(background)))
        return (hi + 0.05) / (lo + 0.05)
    }
}

private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
    zip(a, zip(b, c)).map { ($0, $1.0, $1.1) }
}
