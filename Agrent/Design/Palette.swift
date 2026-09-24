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
    /// #A04E1B. Tabs, buttons, links.
    static let accent = Color(hex: 0xA04E1B)
    /// #7A3A12. Pressed, and text on the ochre chip.
    static let accentDeep = Color(hex: 0x7A3A12)

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
