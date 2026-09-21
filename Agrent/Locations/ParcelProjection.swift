import CoreGraphics
import Foundation

/// Maps WGS84 lon/lat onto screen points for the schematic (tileless) map.
///
/// Four things this does, each because getting it wrong produces a picture that
/// still looks like a farm:
///
/// 1. **Longitude is scaled by `cos(meanLat)`.** A degree of longitude at 43°N
///    covers only ~0.7295 of the ground a degree of latitude does. Without the
///    correction the map renders **27% flatter** than the land — measured on the
///    real parcels, points land ~50px off in a 520pt view. On a schematic map
///    there is no imagery to notice that against.
///
/// 2. **The scale is UNIFORM.** One number for both axes, `min(fitX, fitY)`.
///    Independent per-axis scales would fill the view exactly and distort every
///    shape doing it.
///
/// 3. **THE CONTENT IS CENTRED ON THE SLACK AXIS.** A uniform scale leaves spare
///    room on one axis; that room is split evenly, so `contentOrigin` is NOT the
///    padding corner. This is stated as its own property, and tested on its own,
///    because top-left anchoring is the more obvious implementation and it
///    reproduces every *x* correctly while being wrong in *y* — on the live
///    bounds, by 36.4px. A test that checked only x would pass.
///
/// 4. **Y is flipped.** Latitude grows north, screen y grows down. Miss it and
///    the farm renders upside down — and because the projection normalises
///    whatever it is handed, that also looks plausible. `ParcelProjectionTests`
///    asserts north maps to a smaller y for exactly this reason.
struct ParcelProjection {

    /// `[minLon, minLat, maxLon, maxLat]` — lon FIRST, as the parcels endpoint
    /// sends it. Same ordering trap as the geometry itself.
    struct Bounds {
        let minLon: Double
        let minLat: Double
        let maxLon: Double
        let maxLat: Double

        init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
            self.minLon = minLon
            self.minLat = minLat
            self.maxLon = maxLon
            self.maxLat = maxLat
        }

        /// From the wire's `bounds` array. `nil` on anything but four finite
        /// numbers in the right order — a malformed bounds should degrade to
        /// "cannot draw", never to a confident wrong picture.
        init?(wire: [Double]) {
            guard wire.count == 4, wire.allSatisfy({ $0.isFinite }) else { return nil }
            guard wire[2] >= wire[0], wire[3] >= wire[1] else { return nil }
            self.init(minLon: wire[0], minLat: wire[1], maxLon: wire[2], maxLat: wire[3])
        }
    }

    let bounds: Bounds
    let size: CGSize
    let padding: CGFloat

    /// Screen points per degree — of latitude, and of `cos`-corrected longitude.
    /// Exposed so the renderer sizes strokes and label offsets in the same space
    /// rather than recomputing it, which is how the two drift apart.
    let scale: CGFloat

    /// Top-left of the projected content. **Centred on the slack axis**, so this
    /// is not `(padding, padding)` unless the content happens to fill the box on
    /// both axes. See point 3 in the type's documentation.
    let contentOrigin: CGPoint

    /// The projected extent, `scale` × the corrected spans.
    let contentSize: CGSize

    /// `cos(meanLat)` — the longitude correction actually applied.
    let longitudeCorrection: Double

    init(bounds: Bounds, size: CGSize, padding: CGFloat = 16) {
        self.bounds = bounds
        self.size = size
        self.padding = padding

        let k = cos((bounds.minLat + bounds.maxLat) / 2 * .pi / 180)
        // A degenerate latitude (a pole) would collapse longitude entirely.
        // Nothing in Bulgaria goes near it, but a zero here would divide later.
        self.longitudeCorrection = k > 0 ? k : 1

        let spanX = (bounds.maxLon - bounds.minLon) * self.longitudeCorrection
        let spanY = bounds.maxLat - bounds.minLat

        let innerW = max(0, size.width - 2 * padding)
        let innerH = max(0, size.height - 2 * padding)

        // A single parcel, or several sharing one point, has zero span on an
        // axis; one axis degenerate is normal (a north-south strip) and the
        // other axis still sets the scale. BOTH degenerate means there is no
        // extent at all and no scale means anything — fall back to 1 so the
        // centring below puts the point in the middle.
        //
        // Written as candidates rather than `.greatestFiniteMagnitude`
        // sentinels on purpose: that value IS `.isFinite`, so a
        // `s.isFinite` guard accepts it and the renderer is handed 1.8e308 to
        // size its strokes against. It would still LOOK right, because
        // `0 * 1.8e308 == 0` puts the point in the centre regardless.
        var candidates: [CGFloat] = []
        if spanX > 0 { candidates.append(innerW / CGFloat(spanX)) }
        if spanY > 0 { candidates.append(innerH / CGFloat(spanY)) }
        let s = candidates.min() ?? 1
        self.scale = s.isFinite && s > 0 ? s : 1

        let cw = CGFloat(spanX) * self.scale
        let ch = CGFloat(spanY) * self.scale
        self.contentSize = CGSize(width: cw, height: ch)
        self.contentOrigin = CGPoint(
            x: padding + (innerW - cw) / 2,
            y: padding + (innerH - ch) / 2
        )
    }

    /// One WGS84 coordinate to a screen point.
    ///
    /// `lon` first in the argument list ONLY because that is the order the wire
    /// uses; the labels are there so a call site cannot silently transpose them.
    func point(lon: Double, lat: Double) -> CGPoint {
        let x = contentOrigin.x
            + CGFloat((lon - bounds.minLon) * longitudeCorrection) * scale
        // maxLat - lat, not lat - minLat: north must map to a SMALLER y.
        let y = contentOrigin.y
            + CGFloat(bounds.maxLat - lat) * scale
        return CGPoint(x: x, y: y)
    }
}
