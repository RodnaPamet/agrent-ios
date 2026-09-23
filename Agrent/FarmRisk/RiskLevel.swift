import SwiftUI

/// How a parcel is reading, from the satellite indices.
///
/// FOUR values, and the fourth is not a fourth severity.
///
/// `good | watch | stress` is a scale. `unknown` is an ABSENT READING —
/// no cloud-free pass in the window, or Earth Engine not configured for
/// this deployment. Placing it on the scale would be inventing a
/// measurement, and the register this app serves is not a place to do
/// that.
///
/// ── The colour is the claim ──
///
/// Same argument as `LogEntryType.chipColors`, and it arrives at the same
/// answer. A severity colour asserts a reading: green says "this parcel
/// is healthy", red says "this parcel is stressed". For a parcel nobody
/// measured BOTH are false, and there is no third severity colour that is
/// true. Neutral asserts nothing, which is the only honest option
/// available — so `unknown` gets the neutral chip, not amber, and not a
/// grey pretending to be a middle value.
enum RiskLevel: String, CaseIterable, LenientDecodable, Sendable {
    case good, watch, stress, unknown

    static var unknownCase: RiskLevel { .unknown }

    /// A reading, or the absence of one.
    var isReading: Bool { self != .unknown }

    var label: String {
        switch self {
        case .good: "Добро"
        case .watch: "За наблюдение"
        case .stress: "Стрес"
        // Not "неизвестно" — the app knows perfectly well; it is the
        // satellite that has nothing to say. The sentence beside the chip
        // names which kind of absence it is.
        case .unknown: "Няма отчет"
        }
    }

    /// The severity ramp, and neutral for the absence.
    ///
    /// The greens and reds come from the same family as the NDVI ramp this
    /// app already draws (`VegetationIndex.ramp` runs #a50026 → #006837),
    /// so a farmer comparing a risk chip against the map overlay sees the
    /// same direction meaning the same thing. Lightened for use as a chip
    /// fill behind text, where the map's saturated values fail contrast.
    var colors: (foreground: Color, background: Color) {
        switch self {
        case .good:    (Color(hex: 0x1F6B3A), Color(hex: 0xE4F1E8))
        case .watch:   (Color(hex: 0x8A5B00), Color(hex: 0xFBF0DC))
        case .stress:  (Color(hex: 0x8E2A22), Color(hex: 0xF7E4E1))
        case .unknown: (Palette.Chip.neutralText, Palette.Chip.neutralFill)
        }
    }

    /// Worst first, so a farmer opening the screen sees what needs
    /// attention without scrolling.
    ///
    /// `unknown` sorts LAST, not first. It is not an emergency, it is a
    /// gap — and putting gaps above real stress would bury the parcel that
    /// needs spraying under the parcels a cloud happened to cover.
    var severityOrder: Int {
        switch self {
        case .stress: 0
        case .watch: 1
        case .good: 2
        case .unknown: 3
        }
    }
}
