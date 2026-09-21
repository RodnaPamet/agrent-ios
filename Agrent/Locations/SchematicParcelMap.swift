import SwiftUI

/// Parcels as a DIAGRAM: each one a square at its true position, sized by its
/// real area and drawn larger than life. No tiles, no network, no MapKit.
///
/// THIS IS NOT A SURVEY AND DOES NOT PRETEND TO BE. The real outlines are one
/// tap away on the satellite view; this view trades shape fidelity for
/// legibility, because at true scale the owner's farm is four shapes a few
/// hundred metres across scattered over nine kilometres — geometrically
/// perfect and nearly unreadable on a phone held at arm's length.
///
/// WHAT IS STILL TRUE HERE, and it is the part worth protecting:
///   - POSITION. Each square is centred on its parcel's real centroid, so
///     which field is north of which, and how far apart they are, is exact.
///   - RELATIVE SIZE. Side length is proportional to the square root of the
///     recorded area, so a 69 ha parcel is genuinely ~5.5x the side of a
///     2.28 ha one. Sizes can be compared to each other.
///
/// WHAT IS DELIBERATELY FALSE: the shape, and the absolute size. Every parcel
/// is a square, and every square is `exaggeration` times larger than the
/// ground truth. Nothing here should be measured off.
///
/// THIS IS THE DEFAULT MAP, and the reason is the offline case. MapKit's first
/// frame depends on tiles it may not have: Apple caches opportunistically, not
/// as a guarantee, so a farmer opening Локации in a field with no coverage can
/// get grey squares where their fields should be. This renderer fetches
/// nothing. Its first frame is the cached GeoJSON and nothing else, which is
/// exactly the case the whole caching layer exists for.
///
/// It also stays legible in direct sun, where satellite imagery washes out,
/// because every colour is chosen rather than photographed.
///
/// NO MAPKIT ON THIS PATH, deliberately and structurally. If this view ever
/// needs an MKMapView mounted to compute a projection or a region, the default
/// has quietly reacquired a dependency on the map engine and the property just
/// bought is gone. All the arithmetic lives in `ParcelProjection`, which is
/// pure and tested.
///
/// WHAT IS NOT DRAWN, and why: the design spec includes path strokes — major
/// #8C8770 at 10px, minor #7E7A63 at 5-6px. THERE IS NO PATH DATA. The parcels
/// payload carries `locationId`, `bounds` and `parcels`, and a parcel carries
/// geometry, crop, soil and tenure — no roads, no tracks, nothing linear. The
/// roads on the reference artboard are illustration. Drawing plausible ones
/// from nothing would put invented tracks on a map somebody navigates a
/// tractor by, so the ground is left bare until there is something real to
/// draw. The colours stay in `Palette.Map` for when there is.
struct SchematicParcelMap: View {
    let parcels: [Parcel]
    let bounds: BoundingBox

    /// Matches the padding the projection's test vectors were computed at.
    private let padding: CGFloat = 16

    /// How much larger than life. ONE NUMBER, on purpose — this is a legibility
    /// dial, and the right value is whatever a person holding the phone says
    /// it is, so it should be trivial to turn.
    ///
    /// At 1 the squares are true to area and, on this farm, too small to read.
    /// At 5 they are comfortably legible and adjacent parcels begin to
    /// overlap, because 5x the side is 25x the area and neighbours genuinely
    /// are close together. That overlap is the honest cost of the exaggeration
    /// rather than a bug: they are drawn back-to-front so the smaller square
    /// stays visible on top.
    var exaggeration: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .background(Palette.Map.ground)
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var labels: [(name: String, at: CGPoint)] = []

        // The projection pads for POINTS; a square has extent, so at 5x the
        // largest one ran off the edge of the canvas — a field half
        // off-screen, which is worse than a smaller layout. Inset by half the
        // biggest square so every parcel is fully drawn.
        //
        // Measured once against the unpadded projection, because the side
        // depends on the scale and the scale depends on the padding. One pass
        // is enough: the second scale is smaller, so its squares are smaller
        // too and still fit.
        let probe = ParcelProjection(
            bounds: ParcelProjection.Bounds(bounds), size: size, padding: padding
        )
        let widest = parcels.compactMap { parcel -> CGFloat? in
            guard let geometry = parcel.geometry else { return nil }
            return Self.squareSide(
                areaHa: parcel.areaHa, geometry: geometry,
                projection: probe, exaggeration: exaggeration
            )
        }.max() ?? 0

        let fitted = min(padding + widest / 2, min(size.width, size.height) / 2 - 8)
        let projection = ParcelProjection(
            bounds: ParcelProjection.Bounds(bounds),
            size: size,
            padding: max(padding, fitted)
        )

        // Largest first. At 5x, neighbours overlap; painting the big ones
        // underneath keeps the small parcel visible instead of swallowed.
        let ordered = parcels.sorted { ($0.areaHa ?? 0) > ($1.areaHa ?? 0) }

        for parcel in ordered {
            guard let geometry = parcel.geometry else { continue }
            let sown = parcel.isSown

            guard let centre = Self.labelAnchor(for: geometry, with: projection) else { continue }
            let side = Self.squareSide(
                areaHa: parcel.areaHa,
                geometry: geometry,
                projection: projection,
                exaggeration: exaggeration
            )
            let square = Path(
                roundedRect: CGRect(
                    x: centre.x - side / 2, y: centre.y - side / 2,
                    width: side, height: side
                ),
                cornerRadius: min(4, side / 8)
            )

            context.fill(
                square,
                with: .color(
                    (sown ? Palette.Map.sownFill : Palette.Map.fallowFill)
                        .opacity(Palette.Map.fillOpacity)
                )
            )
            context.stroke(
                square,
                with: .color(sown ? Palette.Map.sownStroke : Palette.Map.fallowStroke),
                style: StrokeStyle(
                    lineWidth: Palette.Map.strokeWidth,
                    lineJoin: .round,
                    // Dashed means fallow — a second channel besides colour,
                    // so the distinction survives a monochrome screenshot and
                    // colour-blind vision.
                    dash: sown ? [] : Palette.Map.dash
                )
            )

            labels.append((parcel.name, centre))
        }

        // Labels last, so no parcel fill can paint over one — and nudged
        // apart, because on the owner's real farm 15655-19 and 15655-3 are
        // adjacent and their centroids are ~20px apart, which drew the two
        // names on top of each other. Small scattered parcels are the normal
        // case here, not the exception.
        draw(labels: labels, in: &context, size: size)
    }

    /// Place labels, pushing a collision downward until it clears.
    ///
    /// Deliberately simple: one pass, vertical only, giving up after a few
    /// nudges rather than searching. A real placement solver is not worth it
    /// for a handful of parcels, and a label that has drifted far from its
    /// field is worse than one that overlaps slightly.
    private func draw(labels: [(name: String, at: CGPoint)],
                      in context: inout GraphicsContext, size: CGSize) {
        var placed: [CGRect] = []

        for label in labels {
            let text = Text(label.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.Map.label)
            let measured = context.resolve(text).measure(in: size)

            var point = label.at
            var box = CGRect(
                x: point.x - measured.width / 2, y: point.y - measured.height / 2,
                width: measured.width, height: measured.height
            )
            var attempts = 0
            while attempts < 4, placed.contains(where: { $0.insetBy(dx: -2, dy: -1).intersects(box) }) {
                point.y += measured.height + 3
                box.origin.y += measured.height + 3
                attempts += 1
            }

            placed.append(box)
            context.draw(text, at: point)
        }
    }

    // NOTE: outline rendering was removed with the move to squares. Hole
    // handling still matters and still lives on the MapKit path, in
    // `ParcelGeometry.mapPolygons`, where it is separately tested — a hole
    // drawn as land is a real error there because that view IS the outlines.

    /// Area-weighted centroid of the outer ring of the largest polygon.
    ///
    /// Not the bounding-box centre, which drifts badly on an L-shaped field.
    /// A centroid can still fall outside a strongly concave parcel; if that
    /// shows up on real geometry the fix is a pole-of-inaccessibility, not a
    /// nudge.
    static func labelAnchor(
        for geometry: ParcelGeometry, with projection: ParcelProjection
    ) -> CGPoint? {
        let rings = geometry.coordinates.compactMap(\.first)
        guard let outer = rings.max(by: { $0.count < $1.count }), outer.count >= 3
        else { return nil }

        let points = screenPoints(outer, projection)
        guard points.count >= 3 else { return nil }

        var twiceArea: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let cross = a.x * b.y - b.x * a.y
            twiceArea += cross
            x += (a.x + b.x) * cross
            y += (a.y + b.y) * cross
        }
        guard abs(twiceArea) > .ulpOfOne else {
            // Degenerate ring — fall back to the mean rather than dividing by
            // ~zero and flinging the label off-screen.
            return CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
            )
        }
        return CGPoint(x: x / (3 * twiceArea), y: y / (3 * twiceArea))
    }

    /// The side of a parcel's square, in points.
    ///
    /// Proportional to the SQUARE ROOT of the area, so that AREA — not edge
    /// length — is what scales with the real figure. Sizing the side directly
    /// by hectares would make a 69 ha parcel look thirty times a 2.28 ha one
    /// rather than five and a half.
    ///
    /// Metres reach points through the projection's own scale, so the squares
    /// stay consistent with the positions around them at any view size. A
    /// degree of latitude is ~111,320 m everywhere, which is why the
    /// conversion uses the latitude axis and not the longitude one — that is
    /// the axis the projection already normalised the cosine out of.
    ///
    /// Falls back to the parcel's real extent when `areaHa` is missing, so a
    /// parcel without a recorded area is still drawn at roughly its own size
    /// rather than vanishing or defaulting to some arbitrary square.
    static func squareSide(
        areaHa: Double?,
        geometry: ParcelGeometry,
        projection: ParcelProjection,
        exaggeration: CGFloat
    ) -> CGFloat {
        let metresPerDegreeLatitude = 111_320.0
        let pointsPerMetre = projection.scale / CGFloat(metresPerDegreeLatitude)

        if let areaHa, areaHa > 0 {
            let sideMetres = (areaHa * 10_000).squareRoot()
            return CGFloat(sideMetres) * pointsPerMetre * exaggeration
        }

        // No recorded area: use the on-screen extent of the outline itself.
        let points = geometry.coordinates
            .compactMap(\.first)
            .flatMap { screenPoints($0, projection) }
        guard points.count >= 3 else { return 8 * exaggeration }
        let width = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let height = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        return max(4, (width + height) / 2) * exaggeration
    }

    /// THE ONE PLACE A GeoJSON POSITION BECOMES A SCREEN POINT.
    ///
    /// GeoJSON is [lon, lat]; the projection takes them named. Getting this
    /// call backwards leaves `ParcelProjection`'s own tests perfectly green
    /// and still draws a transposed farm — and on a schematic map there is no
    /// imagery to notice against, unlike the satellite view where the Hemus
    /// motorway gave it away. Hence one function, and a test that asserts
    /// where the OUTPUT lands rather than what the code says.
    static func screenPoints(_ ring: [[Double]], _ projection: ParcelProjection) -> [CGPoint] {
        ring.compactMap { position in
            guard position.count >= 2 else { return nil }
            return projection.point(lon: position[0], lat: position[1])
        }
    }

    private var accessibilitySummary: String {
        let drawable = parcels.filter(\.isDrawable).count
        let sown = parcels.filter { $0.isDrawable && $0.isSown }.count
        return "Схематична карта: \(drawable) парцела, \(sown) засети."
    }
}

extension ParcelProjection.Bounds {
    /// The single decode path off the wire feeding the single projection
    /// input. Non-failable on purpose: a `BoundingBox` that exists has already
    /// been ordering-checked at its decoder, so there is nothing left to
    /// reject here.
    init(_ box: BoundingBox) {
        self.init(
            minLon: box.minLon, minLat: box.minLat,
            maxLon: box.maxLon, maxLat: box.maxLat
        )
    }
}

extension Parcel {
    /// Sown versus fallow is INFERRED from whether a crop is recorded — the
    /// server has no such field. It is the only signal available and it
    /// matches what the legend claims, but it is an inference: a parcel sown
    /// with an unrecorded crop reads as fallow here.
    var isSown: Bool { !(cropType ?? "").isEmpty }
}
