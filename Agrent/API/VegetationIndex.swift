import Foundation
import SwiftUI

/// The five vegetation indices Earth Engine serves for a location.
///
/// Index NAMES stay as they are — NDVI, NDMI, NDRE, GNDVI, EVI are
/// international agronomy terms and an agronomist reads them in any
/// language. The DESCRIPTIONS and the legend ends are Bulgarian.
///
/// ── The legend labels did not exist in any language ──
///
/// `lowLabel`/`highLabel` are literals in `vegetation-indices.ts` —
/// `'Low'`, `'High'`, `'Dry'`, `'Wet'` — and both web render sites print
/// them raw, so a Bulgarian operator reads "Low"/"High" under the legend
/// today. There was no vocabulary to take, which made this the FIRST
/// rather than a fifth. Agreed with the server side and being made
/// canonical in `messages/` so the two clients cannot drift.
enum VegetationIndex: String, CaseIterable, Identifiable, Sendable {
    case ndvi, ndmi, ndre, gndvi, evi

    var id: String { rawValue }

    var name: String { rawValue.uppercased() }

    var explanation: String {
        switch self {
        case .ndvi: "Зеленина и гъстота на посева"
        case .ndmi: "Влага в посева и почвата"
        case .ndre: "Хлорофил по ръба на червеното"
        case .gndvi: "Хлорофил в зеления спектър"
        case .evi: "Зеленина с корекция за атмосфера и почва"
        }
    }

    /// The ends of the ramp, in words. NDMI measures moisture and reads
    /// dry-to-wet; the rest read low-to-high, and calling moisture "low"
    /// would be true and useless.
    var lowLabel: String { self == .ndmi ? "Сухо" : "Ниска" }
    var highLabel: String { self == .ndmi ? "Влажно" : "Висока" }

    /// The web's ramps, verbatim, low → high. Taken rather than chosen:
    /// an operator comparing a phone against a laptop must see the same
    /// colour mean the same number.
    var ramp: [Color] {
        switch self {
        case .ndvi:  ["a50026", "f46d43", "fee08b", "a6d96a", "006837"].map(Color.init(hex:))
        case .ndmi:  ["a50026", "f46d43", "fee090", "abd9e9", "313695"].map(Color.init(hex:))
        case .ndre:  ["762a83", "c2a5cf", "f7f7f7", "a6dba0", "00441b"].map(Color.init(hex:))
        case .gndvi: ["ffffe5", "d9f0a3", "78c679", "238443", "004529"].map(Color.init(hex:))
        // EVI shares NDVI's ramp: both read canopy vigour low→high, and
        // giving them different colours would imply a difference in what
        // the number means rather than in how it is computed.
        case .evi:   ["a50026", "f46d43", "fee08b", "a6d96a", "006837"].map(Color.init(hex:))
        }
    }
}

private extension Color {
    init(hex string: String) {
        let value = UInt32(string, radix: 16) ?? 0
        self.init(hex: value)
    }
}

/// One index's tiles for one location, at one date.
struct IndexTiles: Decodable, Equatable, Sendable {
    /// False when Earth Engine is not configured for this deployment.
    /// HIDE the buttons rather than showing an error — "not set up" and
    /// "broken" want different faces, especially on a screen an operator
    /// in a field reaches.
    let configured: Bool

    /// An XYZ template — `…/{z}/{x}/{y}` — fetched by the map with NO
    /// auth. The JSON call above it carries the bearer; the tiles do not.
    /// That is what makes this buildable on MapKit at all.
    ///
    /// EPHEMERAL: cached six hours server-side, inside the Earth Engine
    /// mapid lifetime. Re-requested rather than persisted — a stale mapid
    /// 404s per tile, which renders as a map that is simply broken.
    let tileUrl: String

    /// THE ACQUISITION DATE, and it may be OLDER than the date asked for.
    ///
    /// The composite is the 30 days ending on the requested date, and the
    /// collection is adaptive: if cloud masking leaves nothing usable it
    /// reaches further back. Measured on this farm — asking for today
    /// returned 2026-09-19, three days earlier, on the first call.
    ///
    /// So this is rendered, always. A vegetation overlay with no
    /// acquisition date is a picture a farmer will assume is current, and
    /// deciding where to spray from a fortnight-old canopy is the kind of
    /// mistake the screen would have caused rather than prevented.
    let date: String?

    var isUsable: Bool { configured && !tileUrl.isEmpty }
}

enum AgroAPI {
    /// `locationId` is REQUIRED. Tiles are clipped to that location's
    /// parcel geometry, so imagery appears only over the farm's own
    /// fields — empty space outside them is correct, not a load failure.
    ///
    /// No `date` parameter: the server defaults to today and adapts
    /// backwards, which is the behaviour wanted. Passing one would also
    /// put a date in a URL for no gain.
    static func path(_ index: VegetationIndex, locationID: String) -> String {
        let escaped = locationID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? locationID
        return "/api/t/\(Config.tenantSlug)/agro/\(index.rawValue)-tiles?locationId=\(escaped)"
    }

    /// Deliberately NOT through `CachedResource`.
    ///
    /// Every other list in this app is network-first with a cache fallback,
    /// because a stale parcel list is still a parcel list. A stale `tileUrl`
    /// is not a stale map — the Earth Engine mapid inside it expires and each
    /// tile then 404s, so the cache would faithfully serve the one value in
    /// the app whose age makes it useless. This asks the server every time;
    /// the server holds its own six-hour cache, which is the right place for
    /// it because only the server can tell when the mapid was minted.
    static func tiles(_ index: VegetationIndex, locationID: String) async throws -> IndexTiles {
        try await APIClient.shared.get(path(index, locationID: locationID), as: IndexTiles.self)
    }
}
