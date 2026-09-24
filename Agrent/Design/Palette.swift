import SwiftUI

/// The app's colour, taken from the design canvas "Agrent iOS Design
/// Direction" rather than invented here.
///
/// WHY THE ACCENT IS OCHRE AND NOT GREEN, which is the load-bearing decision:
/// green on the parcel map is DATA — it encodes whether a parcel is sown. An
/// app accent in the same family would read as one more state, so the accent
/// is deliberately a colour the map never uses.
///
/// WHAT IS *NOT* DEFINED HERE, on purpose. The canvas's neutrals — #F2F2F7
/// grouped background, #E5E5EA separator, #5A5A5F secondary text, #8A8A8E
/// tertiary — are the iOS light system palette. Reproducing them as literals
/// would pin the app to light mode for no gain, so those stay as SwiftUI's
/// semantic colours: identical in light, and dark mode keeps working. Only
/// genuinely brand-specific values are literals below.
///
/// The canvas specifies no dark appearance. Where a brand colour needs one it
/// is derived here and marked as derived, not taken from the canvas.
enum Palette {
    /// Ochre in light, GOLD in dark. Tabs, buttons, links.
    ///
    /// The gold is the web's `--brand-default #D4AF37`, and it is ALL that
    /// survived a dark theme that also took the web's green surfaces. That
    /// theme shipped half-finished — three screens had green rows and four
    /// still drew black ones — and the owner's call was to put the system's
    /// dark appearance back and keep only the gold. A half-themed app is
    /// worse than an unthemed one.
    ///
    /// It keeps the rule that made the light accent ochre in the first
    /// place: the accent must not be a colour the parcel map uses for DATA.
    /// Green on that map means "this field is sown", and gold is not green.
    static let accent = Color(light: 0xA04E1B, dark: 0xD4AF37)

    /// Pressed, and text on the accent chip. `--brand-emphasis` in dark.
    static let accentDeep = Color(light: 0x7A3A12, dark: 0xB8860B)

    /// The page, in dark only: a very dark green instead of pure black.
    ///
    /// ONE COLOUR, not a page/card pair. The first attempt at a dark theme
    /// had a #05231B page under #0A3327 cards, and getting that right meant
    /// touching every list in the app — I reached three of seven, so three
    /// screens had green rows and four still had black ones. A half-themed
    /// app is worse than an unthemed one, and the owner said so.
    ///
    /// A single value is much harder to get half-right: every surface that
    /// was black becomes the same green, and a screen I miss is obviously
    /// wrong rather than subtly inconsistent.
    ///
    /// LIGHT IS UNTOUCHED — this resolves to `systemBackground` there, so
    /// the shipped light appearance is byte-for-byte what it was.
    ///
    /// Dark enough to read as "not quite black": at #0A1712 the hue is
    /// visible against true black but it never competes with the map's
    /// sown-green, which is the one green in this app that carries meaning.
    enum Surface {
        static let page = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: 0x0A1712))
                : .systemBackground
        })
    }

    /// #B4472A. The ONLY colour that means "something is broken". Reserved:
    /// staleness, refusals and withheld data are not errors and must not
    /// borrow it.
    static let error = Color(hex: 0xB4472A)

    /// Entry-type chips. Two families so a glance separates an input
    /// application from an observation without reading.
    enum Chip {
        static let inputText = Color(hex: 0x7A3A12)
        static let inputFill = Color(hex: 0xF6EBE2)
        static let activityText = Color(hex: 0x274A6D)
        static let activityFill = Color(hex: 0xE7EFF7)
        static let neutralText = Color.secondary
        static let neutralFill = Color(.secondarySystemFill)
    }

    /// The schematic map. Verified against the canvas value by value.
    enum Map {
        static let ground = Color(hex: 0x6E6A52)
        static let pathMajor = Color(hex: 0x8C8770)
        static let pathMinor = Color(hex: 0x7E7A63)
        static let sownFill = Color(hex: 0x3E8E4F)
        static let sownStroke = Color(hex: 0x2C6E3A)
        static let fallowFill = Color(hex: 0x9A9560)
        static let fallowStroke = Color(hex: 0x6F6B3E)
        static let label = Color.white
        /// The coordinate grid. Shares the minor-path value deliberately —
        /// same family, no new colour introduced into a closed palette — but
        /// named separately because it means something else, and because
        /// path strokes will want their own value the day there is path data.
        static let graticule = Color(hex: 0x7E7A63)
        static let graticuleLabel = Color(hex: 0xC9C4A8)
        static let fillOpacity: Double = 0.55
        static let strokeWidth: CGFloat = 2.5
        static let dash: [CGFloat] = [7, 5]

        /// Increase Contrast is not a preference about taste. It is switched
        /// on by people who cannot reliably separate two mid-tone colours,
        /// and on this map the fill IS the data: #3E8E4F sown against
        /// #9A9560 fallow, both at 0.55 over a #6E6A52 ground, is three
        /// muted earth tones within a narrow band of each other. That is a
        /// deliberate choice for direct sunlight and the wrong one here.
        ///
        /// So the fill goes near-solid and the stroke thickens — the parcel
        /// stops being a tint over the ground and becomes a bordered object.
        /// The dashed/solid distinction is untouched because it already
        /// works: it is the non-colour channel, and it is what keeps the map
        /// readable in a monochrome screenshot.
        static func fillOpacity(_ contrast: ColorSchemeContrast) -> Double {
            contrast == .increased ? 0.92 : fillOpacity
        }

        static func strokeWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? 3.5 : strokeWidth
        }
    }
}

extension Color {
    /// One colour, two appearances — resolved by the system rather than by
    /// anything reading `@Environment(\.colorScheme)`.
    ///
    /// A literal cannot answer "which appearance is this?", and a value read
    /// from the environment cannot reach a `UIColor` inside a MapKit
    /// renderer or a UIKit appearance proxy. A dynamic `UIColor` answers in
    /// both places.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
