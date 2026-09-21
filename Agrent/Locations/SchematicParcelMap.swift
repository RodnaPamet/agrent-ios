import SwiftUI

/// Parcels drawn from their own coordinates — no tiles, no network, no MapKit.
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
        let projection = ParcelProjection(
            bounds: ParcelProjection.Bounds(bounds),
            size: size,
            padding: padding
        )

        for parcel in parcels {
            guard let geometry = parcel.geometry else { continue }
            let sown = parcel.isSown

            for polygon in geometry.coordinates {
                guard let path = Self.path(for: polygon, with: projection) else { continue }

                // evenOdd is what makes a hole a hole. Every ring of the
                // polygon goes into ONE path — ring 0 the outline, the rest
                // the holes — and the even-odd rule punches them out. Filling
                // each ring separately would paint the holes solid, which on
                // the owner's real parcel 15655-19 means four invented
                // hectares of crop across a 32-hectare field.
                context.fill(
                    path,
                    with: .color(
                        (sown ? Palette.Map.sownFill : Palette.Map.fallowFill)
                            .opacity(Palette.Map.fillOpacity)
                    ),
                    style: FillStyle(eoFill: true)
                )
                context.stroke(
                    path,
                    with: .color(sown ? Palette.Map.sownStroke : Palette.Map.fallowStroke),
                    style: StrokeStyle(
                        lineWidth: Palette.Map.strokeWidth,
                        lineJoin: .round,
                        // Dashed means fallow — a second channel besides
                        // colour, so the distinction survives a monochrome
                        // screenshot and colour-blind vision.
                        dash: sown ? [] : Palette.Map.dash
                    )
                )
            }

            if let anchor = Self.labelAnchor(for: geometry, with: projection) {
                labels.append((parcel.name, anchor))
            }
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

    /// One `Path` per GeoJSON polygon, every ring included.
    static func path(for polygon: [[[Double]]], with projection: ParcelProjection) -> Path? {
        var path = Path()
        var drew = false
        for ring in polygon {
            let points = screenPoints(ring, projection)
            guard points.count >= 3 else { continue }
            path.move(to: points[0])
            path.addLines(Array(points.dropFirst()))
            path.closeSubpath()
            drew = true
        }
        return drew ? path : nil
    }

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
