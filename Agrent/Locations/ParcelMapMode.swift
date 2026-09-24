import Foundation

/// The three ways this screen can draw a farm.
///
/// Still ONE BUTTON. It cycles rather than opening a picker, which is what
/// the original two-state toggle was asked not to become — and the labels
/// name the mode the button will take you TO, so the control says where it
/// goes rather than where you are.
///
/// The order is not arbitrary. It runs from most detail to least: true
/// outlines with imagery and vegetation data, then rectangles over imagery,
/// then no imagery at all. Pressing repeatedly strips the screen down, which
/// is the direction a farmer moves when the sun is bright or the signal is
/// poor.
enum ParcelMapMode: String, CaseIterable, Sendable {
    /// True GeoJSON outlines with their holes, over Apple's imagery, with the
    /// vegetation indices. The default, and the owner's choice for it.
    case precise

    /// One rectangle per parcel — its bounding box — over imagery, coloured
    /// sown or fallow. No index tiles: Earth Engine clips them to the true
    /// shape, so under a box the colour would stop short of the corners.
    case simplified

    /// No imagery at all. Drawn from the coordinates onto a flat ground in
    /// colours that are ours, so it needs no tiles and holds up in direct
    /// sun. This is the one that still renders with no signal.
    case schematic

    var next: ParcelMapMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// Names the mode itself, in Bulgarian, as a button's title naming a
    /// destination.
    var label: String {
        switch self {
        case .precise: return "Точни очертания"
        case .simplified: return "Опростена"
        case .schematic: return "Схема"
        }
    }

    var icon: String {
        switch self {
        case .precise: return "pentagon"
        case .simplified: return "square.dashed"
        case .schematic: return "square.on.square.dashed"
        }
    }

    /// Said to VoiceOver as what the press will do.
    var hint: String {
        switch self {
        case .precise: return "Превключва към точните очертания на парцелите"
        case .simplified: return "Превключва към опростена карта с правоъгълни парцели"
        case .schematic: return "Превключва към схематична карта без сателитни снимки"
        }
    }

    /// Whether this mode draws parcels by crop state rather than uniformly —
    /// which is exactly when the sown/fallow key belongs on screen.
    var showsSownFallow: Bool { self != .precise }

    /// Whether this mode is drawn by MapKit. The schematic is a Canvas and
    /// has no camera to command and nothing to point a target button at.
    var isSatellite: Bool { self != .schematic }
}
