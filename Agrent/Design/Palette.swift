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
    /// Gold is the web's brand colour — `--brand-default #D4AF37` — and the
    /// owner asked for the phone's dark mode to match. It keeps the rule
    /// that made the light accent ochre: the accent must not be a colour
    /// the parcel map uses for DATA, and gold is not green.
    static let accent = Color(light: 0xA04E1B, dark: 0xD4AF37)

    /// Pressed, and text on the accent chip. `--brand-emphasis` in dark.
    static let accentDeep = Color(light: 0x7A3A12, dark: 0xB8860B)

    /// The dark theme's ground, from the web's `--bg-page` / `--bg-default`.
    ///
    /// GREEN AS SURFACE IS THE WEB'S RULE, AND IT COLLIDES WITH THIS APP'S.
    /// There, green is the page and never a signal; here, green on the
    /// parcel map means "this field is sown". Dropping a saturated green
    /// ground under that would dissolve the signal into the surface.
    ///
    /// What transfers is not the hexes but the pair of moves the web made:
    /// pull the ground down in saturation and lightness until it recedes,
    /// and push the signal up until it out-luminates the ground. So these
    /// are their values — #05231B and #0A3327, the flag's green taken far
    /// down — and `Map.sownFill` brightens in dark to stay above them.
    ///
    /// Light is untouched. The web's light palette is a different palette
    /// rather than the same hues relit, and this app's light mode is
    /// shipped and was not asked about.
    enum Surface {
        static let page = Color(light: 0xF2F2F7, dark: 0x05231B)
        static let card = Color(light: 0xFFFFFF, dark: 0x0A3327)
    }

    /// #B4472A. The ONLY colour that means "something is broken". Reserved:
    /// staleness, refusals and withheld data are not errors and must not
    /// borrow it.
    static let error = Color(hex: 0xB4472A)

    /// Entry-type chips. Two families so a glance separates an input
    /// application from an observation without reading.
    enum Chip {
        static let inputText = Color(light: 0x7A3A12, dark: 0xE4C55C)
        static let inputFill = Color(light: 0xF6EBE2, dark: 0x1F2A16)
        static let activityText = Color(light: 0x274A6D, dark: 0x9FC6F5)
        static let activityFill = Color(light: 0xE7EFF7, dark: 0x13263A)
        static let neutralText = Color.secondary
        static let neutralFill = Color(.secondarySystemFill)
    }

    /// The schematic map. Verified against the canvas value by value.
    enum Map {
        static let ground = Color(hex: 0x6E6A52)
        static let pathMajor = Color(hex: 0x8C8770)
        static let pathMinor = Color(hex: 0x7E7A63)
        // BRIGHTENED IN DARK so the signal stays above the ground.
        //
        // #3E8E4F over a #0A3327 page is two greens within a narrow band of
        // each other, which is the failure the web names in its own token
        // file: "a success badge on a success-coloured page says nothing".
        // Their answer is to push the signal past stock emerald; #5FE39B is
        // their `--content-success`, and the sown fill takes the same step.
        static let sownFill = Color(light: 0x3E8E4F, dark: 0x5FE39B)
        static let sownStroke = Color(light: 0x2C6E3A, dark: 0x8FF3BE)
        // Fallow moves the other way — away from green entirely, so the two
        // states cannot converge on a green ground.
        static let fallowFill = Color(light: 0x9A9560, dark: 0xD8CE92)
        static let fallowStroke = Color(light: 0x6F6B3E, dark: 0xEFE8BE)
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
    /// A literal cannot answer "which appearance is this?", and a value
    /// read from the environment cannot reach a `UIColor` inside a MapKit
    /// renderer or a UIKit appearance proxy. A dynamic `UIColor` answers in
    /// both places, which is why the bridge is here rather than at each
    /// call site.
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
