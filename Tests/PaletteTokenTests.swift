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
        // The three speakers of a conversation (agri-saas #1323). Bubble text
        // is body size, so 4.5:1. The other side's pair was "measured by
        // nobody" before this (ROADMAP's device checks); it is measured here.
        ("my bubble", Palette.Bubble.mineInk, Palette.Bubble.mineFill, [8.45, 5.21, 5.21]),
        ("colleague's bubble", Palette.Bubble.colleagueInk, Palette.Bubble.colleagueFill, [7.33, 5.29, 5.83]),
        ("other side's bubble", Palette.Bubble.theirsInk, Palette.Bubble.theirsFill, [13.57, 17.50, 19.26]),
        // P2.8 solid surfaces: everything written on a bar. `Color.primary`
        // is what the composer, the outbox banner, the map's target glyph
        // and the index chips write in; `secondaryText` is the unselected
        // tab and the map's failure line; `accent` the selected tab.
        ("accent on bar", Palette.accent, Palette.Surface.bar, [6.59, 5.09, 5.49]),
        ("secondaryText on bar", Palette.secondaryText, Palette.Surface.bar, [7.64, 7.24, 11.37]),
        ("warning on bar", Palette.warning, Palette.Surface.bar, [8.30, 6.48, 7.13]),
        ("error on bar", Palette.error, Palette.Surface.bar, [6.05, 7.85, 7.75]),
        ("success on bar", Palette.success, Palette.Surface.bar, [8.54, 6.83, 8.08]),
        ("primary on bar", Color.primary, Palette.Surface.bar, [13.85, 19.47, 21.00]),
        ("primary on page (navigation titles)", Color.primary, Palette.Surface.page, [16.63, 18.77, 21.00]),
        ("secondaryText on card", Palette.secondaryText, Palette.Surface.card, [7.64, 7.24, 11.37]),
        ("primary on card", Color.primary, Palette.Surface.card, [13.85, 19.47, 21.00]),
        // #156: the ten forms' rows are `Surface.card` (`PageForm`). Their
        // labels and fields are `primary`, their hints `secondaryText` (both
        // above); these are the rest a form row writes — a button or a
        // picker's value in the accent, a failure, a caveat.
        ("accent on card (form buttons)", Palette.accent, Palette.Surface.card, [6.59, 5.09, 5.49]),
        ("error on card (form failures)", Palette.error, Palette.Surface.card, [6.05, 7.85, 7.75]),
        ("warning on card (form caveats)", Palette.warning, Palette.Surface.card, [8.30, 6.48, 7.13]),
        // #156: a form's footers and headers sit on `formPage`, which is the
        // page in dark and light and `--bg-muted` in «Слънце».
        ("secondaryText on formPage (footers)", Palette.secondaryText, Palette.Surface.formPage, [9.17, 6.98, 9.28]),
        ("warning on formPage", Palette.warning, Palette.Surface.formPage, [9.96, 6.24, 5.82]),
        ("error on formPage", Palette.error, Palette.Surface.formPage, [7.26, 7.57, 6.33]),
        // #156: the composer, a token-drawn field on the bar.
        ("field text", Palette.Field.text, Palette.Field.fill, [13.85, 19.47, 21.00]),
        ("field placeholder", Palette.Field.placeholder, Palette.Field.fill, [5.81, 5.32, 7.46]),
        // #150: Админ's row values, on page rows.
        ("Админ row value", Palette.secondaryText, Palette.Surface.page, [9.17, 6.98, 11.37]),
        // #159: the text a List or Form draws around its rows, through
        // `Palette.ListChrome` (`FormChrome.swift`). Headers and footers sit
        // on a form's ground or a list's page; values on a form's card or a
        // list's page row; prompts and menu values on the card.
        ("section header on formPage", Palette.ListChrome.header, Palette.Surface.formPage, [9.17, 6.98, 9.28]),
        ("section header on page", Palette.ListChrome.header, Palette.Surface.page, [9.17, 6.98, 11.37]),
        ("row value on card", Palette.ListChrome.value, Palette.Surface.card, [7.64, 7.24, 11.37]),
        ("row value on page", Palette.ListChrome.value, Palette.Surface.page, [9.17, 6.98, 11.37]),
        ("field prompt on card", Palette.ListChrome.placeholder, Palette.Surface.card, [5.81, 5.32, 7.46]),
        ("menu picker value on card", Palette.ListChrome.menuValue, Palette.Surface.card, [6.59, 5.09, 5.49]),
        // Five lists are not on token surfaces yet — the tab customiser, a
        // listing's detail, the calculator, the dashboard's block picker and
        // the pages a `.navigationLink` picker pushes — so their headers sit
        // on `systemGroupedBackground` and their values on
        // `secondarySystemGroupedBackground`, resolved here with the same
        // traits (Increase Contrast included).
        ("section header on systemGroupedBackground", Palette.ListChrome.header,
         Color(uiColor: .systemGroupedBackground), [11.57, 7.00, 9.57]),
        ("row value on secondarySystemGroupedBackground", Palette.ListChrome.value,
         Color(uiColor: .secondarySystemGroupedBackground), [9.38, 7.81, 11.37]),
    ]

    /// The one role that does NOT pass on a bar, written down so nobody
    /// puts it there: `accentDeep` on `Surface.bar` in dark is 4.26. Today
    /// it is used only on the page (a sent message's timestamp, two chart
    /// series), where it is 5.11. If this ever starts passing, the token
    /// moved and `Palette.Surface.bar`'s note can drop the warning.
    func testAccentDeepOnTheDarkBarIsTheKnownShortfall() {
        let ratio = Self.contrast(Palette.accentDeep, on: Palette.Surface.bar, Self.dark)
        XCTAssertEqual(ratio, 4.26, accuracy: 0.02)
        XCTAssertLessThan(ratio, 4.5)
    }

    /// The composer's EDGE is the field's whole boundary (its fill is the
    /// bar it sits on), so it is a non-text pair held to 3:1 against the
    /// bar — in «Слънце» too, where bar and page are both white. The web's
    /// `--ctrl-edge-rest`, which `Palette.Field` declines, is the positive
    /// control: it measures the 1.5 that comment cites, and fails.
    func testTheComposerEdgeIsVisibleInEveryArm() {
        for (traits, expected) in zip([Self.dark, Self.light, Self.sunlight], [5.81, 5.32, 7.46]) {
            let ratio = Self.contrast(Palette.Field.edge, on: Palette.Surface.bar, traits)
            XCTAssertGreaterThanOrEqual(ratio, 3)
            XCTAssertEqual(ratio, expected, accuracy: 0.02)
        }
        let web = Self.contrast(Color(token: AgrentColor.ctrlEdgeRest), on: Palette.Surface.bar, Self.light)
        XCTAssertEqual(web, 1.50, accuracy: 0.02)
        XCTAssertLessThan(web, 3)
    }

    /// A form's card rows differ from the ground under them in EVERY arm —
    /// the point of `formPage`. The plain page is the positive control: in
    /// «Слънце» it equals the card, which is the white-on-white form the
    /// first #156 capture showed.
    func testFormCardsStandOffTheirGroundInEveryArm() {
        for (traits, arm) in zip([Self.dark, Self.light, Self.sunlight], ["dark", "light", "«Слънце»"]) {
            XCTAssertNotEqual(Self.rgba(Palette.Surface.card, traits), Self.rgba(Palette.Surface.formPage, traits), arm)
        }
        XCTAssertEqual(Self.rgba(Palette.Surface.card, Self.sunlight), Self.rgba(Palette.Surface.page, Self.sunlight))
        XCTAssertEqual(Self.rgba(Palette.Surface.formPage, Self.dark), Self.rgba(Palette.Surface.page, Self.dark))
        XCTAssertEqual(Self.rgba(Palette.Surface.formPage, Self.light), Self.rgba(Palette.Surface.page, Self.light))
    }

    /// The exchange map's oblast boundary against the idle oblast fill, the
    /// fill composited over the page. BELOW 3:1 by documented choice (see
    /// `Palette.RegionMap`); pinned so the numbers in that comment stay true
    /// and a token change that moves them is seen.
    func testTheRegionMapBoundaryIsTheDocumentedShortfall() {
        for (traits, expected) in zip([Self.dark, Self.light, Self.sunlight], [2.6, 2.1, 2.3]) {
            let page = Self.rgba(Palette.Surface.page, traits)
            let idle = Self.over(Self.rgba(Palette.RegionMap.idleFill, traits), page)
            let line = Self.over(Self.rgba(Palette.RegionMap.boundary, traits), idle)
            XCTAssertEqual(Self.ratio(line, idle), expected, accuracy: 0.1)
        }
    }

    /// The map's index chips: `Chip.neutralFill` is translucent, and it sits
    /// on the BAR, not the page — so it is composited over the bar here,
    /// which the generic helper (fill over page) would get wrong.
    func testIndexChipOnTheBar() {
        for (traits, expected) in zip([Self.dark, Self.light, Self.sunlight], [11.71, 18.12, 19.26]) {
            let bar = Self.over(Self.rgba(Palette.Surface.bar, traits), Self.rgba(Palette.Surface.page, traits))
            let chip = Self.over(Self.rgba(Palette.Chip.neutralFill, traits), bar)
            let ratio = Self.ratio(Self.over(Self.rgba(Color.primary, traits), chip), chip)
            XCTAssertGreaterThanOrEqual(ratio, 4.5)
            XCTAssertEqual(ratio, expected, accuracy: 0.02)
        }
    }

    /// Every surface P2.8 introduced is OPAQUE, in every arm — the point of
    /// the change. The hairline is the one translucent token, and it is
    /// decoration.
    func testTheSolidSurfacesAreOpaque() {
        for traits in [Self.dark, Self.light, Self.sunlight, Self.darkIncreased] {
            for (name, colour) in [("page", Palette.Surface.page), ("bar", Palette.Surface.bar),
                                   ("card", Palette.Surface.card)] {
                XCTAssertEqual(Self.rgba(colour, traits)[3], 1, "\(name) must be opaque")
            }
        }
    }

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

    /// The three bubbles are three OBJECTS, not one colour three times: in
    /// every arm each pair of fills differs, and the colleague's edge is a
    /// non-text boundary at 3:1 or more against the page it sits on.
    func testTheThreeBubblesAreTellableApart() {
        for (traits, arm) in zip([Self.dark, Self.light, Self.sunlight], ["dark", "light", "«Слънце»"]) {
            let page = Self.rgba(Palette.Surface.page, traits)
            let fills = [Palette.Bubble.mineFill, Palette.Bubble.colleagueFill, Palette.Bubble.theirsFill]
                .map { Self.over(Self.rgba($0, traits), page) }
            XCTAssertEqual(Set(fills).count, 3, "\(arm): two bubbles share a fill")
            let edge = Self.contrast(Palette.Bubble.colleagueEdge, on: Palette.Surface.page, traits)
            XCTAssertGreaterThanOrEqual(edge, 3, "\(arm): the colleague's edge \(edge)")
        }
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
        return ratio(foreground, background)
    }

    /// WCAG 2.x contrast of two opaque colours.
    private static func ratio(_ foreground: [Double], _ background: [Double]) -> Double {
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
