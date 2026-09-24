import CoreGraphics
import Foundation

/// Bulgaria's 28 oblasti, pre-projected.
///
/// ── Why the bundled asset and not the GeoJSON ──
///
/// The server publishes both `bg-map-geometry.json` (pre-projected paths
/// for a 1000×600 space) and `bg-oblasti.geojson` (raw polygons). This
/// takes the first, for three reasons:
///
/// 1. The paths use **M, L and Z only** — no curves — so parsing is a scan
///    for numbers rather than an SVG engine. Verified across all 28: 28
///    `M`, 3062 `L`, 28 `Z`, and nothing else.
/// 2. The shapes are then IDENTICAL to the web's, rather than equivalent.
///    Two clients drawing the same country slightly differently is the
///    kind of difference nobody can explain later.
/// 3. It is 41 KB against 66 KB, and it is BUNDLED — so the map draws with
///    no network, which is the same argument the schematic parcel map is
///    built on — now one of three modes there rather than the default. A
///    border does not change between releases.
///
/// ── The projection is the file's own, verified rather than inferred ──
///
///     x = ox + (lon − minX) · cos · s
///     y = oy + (maxY − lat) · s
///
/// Checked by projecting the declared bounds and comparing to the actual
/// bounding box of all 3062 path points: both give x 51.8…948.2, y
/// 10.0…590.0, matching to under a pixel. So a listing's lat/lon lands in
/// exactly the same space as the polygons, with nothing guessed.
///
/// `cos` is the latitude correction — the same trick `ParcelProjection`
/// uses, at country scale instead of field scale.
struct BulgariaMap {
    let width: CGFloat
    let height: CGFloat
    let outline: [CGPoint]
    let oblasti: [Oblast]
    private let proj: Projection

    struct Oblast: Identifiable, Equatable {
        /// `BG-01` … `BG-28`. The IDENTITY — the label comes from
        /// `BulgarianRegion`, never from the file's `name`, which is
        /// English.
        let iso: String
        let points: [CGPoint]
        var id: String { iso }
    }

    private struct Projection: Decodable {
        let minX, maxX, minY, maxY, cos, ox, oy, s: Double
    }

    private struct File: Decodable {
        let W: Double
        let H: Double
        let proj: Projection
        let outlinePath: String
        let oblasti: [Entry]
        struct Entry: Decodable { let d: String; let iso: String }
    }

    /// Where a listing sits, in the same space as the polygons.
    ///
    /// The server derives `lat`/`lon` from the region code against the ISO
    /// catalogue, so every listing in an oblast sits on that oblast's
    /// CENTROID. The markers are not parcel-accurate and are not meant to
    /// be — worth knowing before anyone reads a cluster as a location.
    func point(lat: Double, lon: Double) -> CGPoint {
        CGPoint(
            x: proj.ox + (lon - proj.minX) * proj.cos * proj.s,
            y: proj.oy + (proj.maxY - lat) * proj.s
        )
    }

    static func bundled() -> BulgariaMap? {
        guard let url = Bundle.main.url(forResource: "bg-map-geometry", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return BulgariaMap(data: data)
    }

    init?(data: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        self.width = file.W
        self.height = file.H
        self.proj = file.proj
        self.outline = Self.parse(file.outlinePath)
        self.oblasti = file.oblasti.compactMap { entry in
            let points = Self.parse(entry.d)
            guard points.count >= 3 else { return nil }
            return Oblast(iso: entry.iso, points: points)
        }
    }

    /// `M x y L x y … Z` — a scan for numbers in pairs.
    ///
    /// Deliberately NOT a general SVG path parser. The command set was
    /// measured across all 28 paths and the national outline and is
    /// exactly M, L and Z; a parser that also handled curves would be
    /// untested code defending against a case the asset does not contain.
    /// If the asset ever gains a `C`, this returns a polygon with the
    /// control points as vertices — visibly wrong rather than silently so,
    /// which is the right failure.
    static func parse(_ path: String) -> [CGPoint] {
        var numbers: [Double] = []
        var current = ""
        for character in path {
            if character.isNumber || character == "." || character == "-" {
                // A minus begins a new number even without a separator,
                // which is how these paths encode negatives.
                if character == "-", !current.isEmpty {
                    if let value = Double(current) { numbers.append(value) }
                    current = "-"
                } else {
                    current.append(character)
                }
            } else {
                if let value = Double(current) { numbers.append(value) }
                current = ""
            }
        }
        if let value = Double(current) { numbers.append(value) }

        return stride(from: 0, to: numbers.count - 1, by: 2).map {
            CGPoint(x: numbers[$0], y: numbers[$0 + 1])
        }
    }
}
