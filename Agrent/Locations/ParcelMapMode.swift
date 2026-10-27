import Foundation

/// The three ways this screen can draw a farm.
///
/// Still ONE BUTTON. It cycles rather than opening a picker, which is what
/// the original two-state toggle was asked not to become — and the labels
/// name the mode the button will take you TO, so the control says where it
/// goes rather than where you are.
///
/// The order: true outlines over Apple's imagery with the vegetation data,
/// then rectangles coloured sown or fallow, then the Ministry's orthophoto
/// with the outlines and the physical blocks (ФБ), as on a ДФЗ map.
enum ParcelMapMode: String, CaseIterable, Sendable {
    /// True GeoJSON outlines with their holes, over Apple's imagery, with the
    /// vegetation indices. The default, and the owner's choice for it.
    case precise

    /// One rectangle per parcel — its bounding box — over imagery, coloured
    /// sown or fallow. No index tiles: Earth Engine clips them to the true
    /// shape, so under a box the colour would stop short of the corners.
    case simplified

    /// «Ортофотокарта» (#458, owner 2026-10-27): the МЗХ orthophoto, each
    /// parcel's true outline and name, and the physical blocks (ФБ) with
    /// their numbers. It replaced «Схема», whose squares were drawn five
    /// times life and overlapped. True size can't overlap. With no signal
    /// the outlines stay on a plain ground (`OrthophotoTileOverlay`).
    case orthophoto

    var next: ParcelMapMode { next(in: Self.allCases) }

    /// The next of the modes this person has: «Ортофотокарта» is behind the
    /// server's switch (`OrthophotoAPI.flag`). A mode outside the list, a
    /// saved one the switch has since taken away, goes to the first.
    func next(in modes: [ParcelMapMode]) -> ParcelMapMode {
        guard let index = modes.firstIndex(of: self) else { return modes.first ?? .precise }
        return modes[(index + 1) % modes.count]
    }

    /// The modes on offer: all three with the switch on, the first two off.
    static func available(orthophoto: Bool) -> [ParcelMapMode] {
        orthophoto ? allCases : allCases.filter { $0 != .orthophoto }
    }

    /// Names the mode itself, in Bulgarian, as a button's title naming a
    /// destination.
    var label: String {
        switch self {
        case .precise: return "Точни очертания"
        case .simplified: return "Опростена"
        case .orthophoto: return "Ортофотокарта"
        }
    }

    var icon: String {
        switch self {
        case .precise: return "pentagon"
        case .simplified: return "square.dashed"
        case .orthophoto: return "photo"
        }
    }

    /// Said to VoiceOver as what the press will do.
    var hint: String {
        switch self {
        case .precise: return "Превключва към точните очертания на парцелите"
        case .simplified: return "Превключва към опростена карта с правоъгълни парцели"
        case .orthophoto: return "Превключва към ортофотокартата на МЗХ с физическите блокове"
        }
    }

    /// Whether this mode draws parcels by crop state rather than uniformly —
    /// which is exactly when the sown/fallow key belongs on screen.
    var showsSownFallow: Bool { self == .simplified }

    /// Every mode is MapKit since «Ортофотокарта» replaced the Canvas
    /// schematic: each has a camera and a target button.
    var isSatellite: Bool { true }
}
