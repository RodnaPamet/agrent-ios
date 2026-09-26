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

    /// THE MAP'S TEXT SCALES NOW, and it did not.
    ///
    /// Parcel names were drawn at a hard `.system(size: 14)` and the graticule
    /// and compass at 11. Fourteen points is already SMALLER than `.body` at
    /// the default setting, and it stayed 14 at the largest accessibility size
    /// while every other word on screen roughly tripled. This is the DEFAULT
    /// map mode on Локации, so a low-vision farmer who turned text up — the
    /// person the setting exists for, and not necessarily a VoiceOver user —
    /// got coloured squares they could not name.
    ///
    /// The list underneath carries the names as text that does scale, but not
    /// POSITION, and this file's whole argument for existing is that position
    /// is the one thing it knows truthfully. `Accessibility.swift` says the
    /// same in its own words about the VoiceOver rebuild of this map.
    ///
    /// ── The trap this fell into is written in this file, twelve lines up ──
    ///
    /// "A `Canvas` draws outside the view hierarchy, so it cannot read the
    /// environment itself — the value has to be captured here and carried in.
    /// Easy to forget, and the failure is silent: the map simply ignores the
    /// setting for the people who turned it on." That is about
    /// `colorSchemeContrast`, which IS captured. `dynamicTypeSize` is the same
    /// trap and is the one that was forgotten.
    ///
    /// ── Clamped, and the clamp has a reason ──
    ///
    /// The label placement solver gives up after four downward nudges and this
    /// file calls it "deliberately simple". Unbounded labels at AX5 would be
    /// three times the size with the same four attempts, so they would pile up
    /// instead of clipping — a different failure, not a better one. 26pt is
    /// roughly the largest that still resolves, and the list below is the
    /// unbounded channel for anyone who needs more.
    @ScaledMetric(relativeTo: .footnote) private var scaledLabelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var scaledChromeSize: CGFloat = 11

    private var labelSize: CGFloat { min(scaledLabelSize, 26) }
    private var chromeSize: CGFloat { min(scaledChromeSize, 20) }

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

    /// Tapping a square opens that parcel. Optional, so the map stays
    /// usable as a pure display anywhere that has nothing to open.
    var onTap: ((Parcel) -> Void)?

    /// A `Canvas` draws outside the view hierarchy, so it cannot read the
    /// environment itself — the value has to be captured here and carried in.
    /// Easy to forget, and the failure is silent: the map simply ignores the
    /// setting for the people who turned it on.
    /// Extra clearance at the top, ON TOP of the safe area the view already
    /// reports. Zero today; kept because the reason it exists has not gone
    /// away, only changed owner — see the note in `body`.
    ///
    /// Measured on the device, 2026-09-22: parcel `20688.13` projected to
    /// y = 95pt and the location card occupied roughly y = 55…190, so one of
    /// the owner's four fields was drawn entirely underneath it. Nothing was
    /// wrong with the projection — the probe showed all four placements
    /// present and correct — the map simply had less usable area than it
    /// thought, and a parcel you cannot see reads as a parcel you do not
    /// have.
    ///
    /// The card is not moved out of the way: floating it over the ground is
    /// the design, and on schematic there is no imagery for it to obscure.
    /// The CONTENT moves instead.
    var topInset: CGFloat = 0

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            // The map is drawn edge to edge, UNDER the navigation bar, which
            // is what makes it read as a map rather than a panel. The cost is
            // that the top strip is occupied by chrome — the back button and
            // the view toggle — and anything drawn there sits behind them.
            //
            // Found the hard way with the location card that used to float
            // here: parcel 20688.13 projected to y=95pt, the card covered
            // roughly y=55…190, and one of the owner's four fields was
            // invisible. The card is gone, but the bar is not, so the
            // clearance is taken from the safe area the view actually
            // reports rather than from a measured overlay. Same defect, same
            // fix, a different thing to measure.
            let clearance = geo.safeAreaInsets.top + topInset

            Canvas { context, size in
                draw(in: &context, size: size, clearance: clearance)
            }
            .background(Palette.Map.ground)
            // A Canvas is one opaque rectangle to VoiceOver. It carried a
            // single summary label, which described the data the parcel list
            // below already reads out better — and dropped POSITION, the one
            // thing this map knows that the list does not. These children put
            // each parcel back on the screen as its own element, at its own
            // place, so the map is navigable rather than merely announced.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityChildren { accessibilityOverlay(in: geo.size, clearance: clearance) }
            // Hit-tested against the SAME `layout` the drawing uses, so a
            // tap cannot land on a square that is not where it appears.
            // Computing a second set of rects here is the drift that the
            // accessibility overlay was extracted to avoid.
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard let onTap else { return }
                let laid = layout(in: geo.size, clearance: clearance)
                // SMALLEST FIRST. At 5x the squares overlap, and the small
                // parcel is drawn ON TOP — so the tap must resolve the same
                // way the eye does, or an operator taps the square they can
                // see and opens the one behind it.
                let hit = laid.placements
                    .sorted { $0.side < $1.side }
                    .first { placement in
                        let centre = CGPoint(
                            x: placement.centre.x, y: placement.centre.y + clearance)
                        return abs(point.x - centre.x) <= placement.side / 2
                            && abs(point.y - centre.y) <= placement.side / 2
                    }
                if let hit { onTap(hit.parcel) }
            }
        }
    }

    /// Invisible proxies, one per drawn square, laid out where the squares
    /// are. Never rendered — `accessibilityChildren` uses this hierarchy only
    /// to build the accessibility tree — so the frames exist purely to give
    /// VoiceOver something to focus and a sensible order to sweep in.
    @ViewBuilder
    private func accessibilityOverlay(in size: CGSize, clearance: CGFloat) -> some View {
        let laid = layout(in: size, clearance: clearance)
        let centre = Self.centroid(of: laid.placements)

        ZStack {
            ForEach(laid.placements, id: \.parcel.id) { placement in
                Color.clear
                    .frame(width: max(placement.side, 1), height: max(placement.side, 1))
                    .position(placement.centre)
                    .accessibilityElement()
                    .accessibilityLabel(Self.label(
                        for: placement, centre: centre, count: laid.placements.count
                    ))
            }
        }
        // Mirrors `context.translateBy` in `draw`.
        .offset(y: clearance)
    }

    /// What one parcel sounds like.
    ///
    /// Sown/fallow is spoken because on screen it is carried by fill colour
    /// and a dashed stroke, and neither reaches this channel at all.
    static func label(
        for placement: Placement, centre: CGPoint, count: Int
    ) -> String {
        let parcel = placement.parcel
        let direction = A11y.compass(
            dx: placement.centre.x - centre.x,
            dy: placement.centre.y - centre.y,
            // A twentieth of the canvas. Below that the bearing is noise
            // dressed as information, and a confident wrong direction on a
            // map is worse than none.
            deadband: max(placement.side, 12) / 2
        )

        return A11y.sentence([
            parcel.name,
            parcel.isSown ? "засят" : "угар",
            CommodityName.freeText(parcel.cropType),
            parcel.areaHa.map { Area(hectares: $0).spoken },
            count == 1 ? nil : (direction ?? "в средата"),
        ])
    }

    static func centroid(of placements: [Placement]) -> CGPoint {
        guard !placements.isEmpty else { return .zero }
        // The midpoint of the EXTENT, not the mean of the centres. Five
        // parcels clustered together and one far off would drag a mean into
        // the cluster and report the five as lying in every direction from
        // themselves.
        let xs = placements.map(\.centre.x)
        let ys = placements.map(\.centre.y)
        return CGPoint(
            x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2,
            y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
        )
    }

    /// Where one parcel's square ends up. Shared by the drawing pass and the
    /// accessibility pass so the two cannot describe different maps.
    struct Placement {
        let parcel: Parcel
        let centre: CGPoint
        let side: CGFloat
    }

    /// The geometry both passes need, computed once from the same inputs.
    ///
    /// Extracted from `draw` rather than duplicated: an accessibility tree
    /// that is computed separately is an accessibility tree that drifts, and
    /// it drifts silently because the person who can see the screen never
    /// notices.
    func layout(in size: CGSize, clearance: CGFloat = 0) -> (
        projection: ParcelProjection, placements: [Placement], usable: CGSize
    ) {
        // Everything below works in USABLE space — the canvas minus the band
        // the card sits in. Both consumers shift into screen space by the
        // same `topInset`, once each and visibly: `translateBy` in `draw`,
        // `.offset` in the accessibility overlay.
        let size = CGSize(
            width: size.width, height: max(size.height - clearance, 1)
        )
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

        let placements = ordered.compactMap { parcel -> Placement? in
            guard let geometry = parcel.geometry,
                  let centre = Self.labelAnchor(for: geometry, with: projection)
            else { return nil }
            return Placement(
                parcel: parcel,
                centre: centre,
                side: Self.squareSide(
                    areaHa: parcel.areaHa, geometry: geometry,
                    projection: projection, exaggeration: exaggeration
                )
            )
        }
        return (projection, placements, size)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, clearance: CGFloat) {
        var labels: [(name: String, at: CGPoint)] = []

        let laid = layout(in: size, clearance: clearance)
        // Mirrored by `.offset(y: topInset)` in `accessibilityOverlay`. If
        // one of these two changes the other must, or the map a screen
        // reader describes is not the map on screen.
        context.translateBy(x: 0, y: clearance)
        drawGraticule(in: &context, size: laid.usable, projection: laid.projection)
        drawNorthArrow(in: &context, size: laid.usable)

        for placement in laid.placements {
            let parcel = placement.parcel
            let sown = parcel.isSown
            let centre = placement.centre
            let side = placement.side
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
                        .opacity(Palette.Map.fillOpacity(contrast))
                )
            )
            context.stroke(
                square,
                with: .color(sown ? Palette.Map.sownStroke : Palette.Map.fallowStroke),
                style: StrokeStyle(
                    lineWidth: Palette.Map.strokeWidth(contrast),
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
        draw(labels: labels, in: &context, size: laid.usable)
    }

    /// A latitude/longitude grid, so position stays readable.
    ///
    /// This matters MORE here than on the satellite view, not less. There the
    /// imagery itself orients you — the Hemus motorway and the village of
    /// Toros are recognisable, which is how the axis order was verified by
    /// eye. Strip the imagery and exaggerate the shapes, and position is the
    /// only thing left that is still true; without a reference it is also the
    /// only thing with nothing to read it against.
    ///
    /// NO SCALE BAR, deliberately, and this is the one judgement worth
    /// stating. Distances BETWEEN parcels are exact, so a scale bar would be
    /// correct for them — but the squares beside it are five times life size,
    /// and a ruler next to a deliberately false shape invites someone to
    /// measure the shape. Coordinates cannot be misread that way: they label
    /// position, which is the thing that is true.
    private func drawGraticule(
        in context: inout GraphicsContext, size: CGSize, projection: ParcelProjection
    ) {
        let lonStep = Self.graticuleStep(forSpan: bounds.lonSpan)
        let latStep = Self.graticuleStep(forSpan: bounds.latSpan)

        // MAJOR AND MINOR, in the design's own path tones.
        //
        // The reference artboard breaks up the flat ground with three strokes
        // — one heavy #8C8770, two lighter #7E7A63. Those are drawn as roads,
        // and there is no road data, so they are not reproduced: inventing
        // tracks on a map somebody drives a tractor by is not a styling
        // decision.
        //
        // But the artboard is right that an unbroken field of one colour
        // reads as empty. So the grid carries that structure instead, at the
        // same two weights and the same two colours — and every line here
        // means something true, which a fake road would not. Every fifth line
        // is major, which at a 0.02° step puts a heavier line every 0.1°.
        let minorStroke = StrokeStyle(lineWidth: 1)
        let majorStroke = StrokeStyle(lineWidth: 2)
        let minorColour = Palette.Map.pathMinor.opacity(0.55)
        let majorColour = Palette.Map.pathMajor.opacity(0.7)

        func isMajor(_ value: Double, step: Double) -> Bool {
            let index = (value / step).rounded()
            return Int(index) % 5 == 0
        }

        // Longitude labels run horizontally and the lines can sit closer
        // together than the text is wide — at this farm's scale they printed
        // as "24.2224.2424.26". A label that cannot fit is DROPPED rather
        // than overprinted: a gridline with no number still orients you, but
        // an unreadable smear of digits is worse than a bare line.
        var lastLabelEnd: CGFloat = -.greatestFiniteMagnitude
        for value in Self.gridValues(from: bounds.minLon, to: bounds.maxLon, step: lonStep) {
            let x = projection.point(lon: value, lat: bounds.maxLat).x
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            let major = isMajor(value, step: lonStep)
            context.stroke(
                line,
                with: .color(major ? majorColour : minorColour),
                style: major ? majorStroke : minorStroke
            )

            let label = gridLabel(value, step: lonStep)
            let width = context.resolve(label).measure(in: size).width
            if x + 4 > lastLabelEnd + 8, x + 4 + width < size.width {
                context.draw(
                    label,
                    at: CGPoint(x: x + 4, y: size.height - 8),
                    anchor: .bottomLeading
                )
                lastLabelEnd = x + 4 + width
            }
        }

        for value in Self.gridValues(from: bounds.minLat, to: bounds.maxLat, step: latStep) {
            let y = projection.point(lon: bounds.minLon, lat: value).y
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            let major = isMajor(value, step: latStep)
            context.stroke(
                line,
                with: .color(major ? majorColour : minorColour),
                style: major ? majorStroke : minorStroke
            )
            context.draw(
                gridLabel(value, step: latStep),
                at: CGPoint(x: 6, y: y - 4),
                anchor: .bottomLeading
            )
        }
    }

    private func gridLabel(_ value: Double, step: Double) -> Text {
        Text(Self.formatDegrees(value, step: step))
            .font(.system(size: chromeSize, weight: .medium).monospacedDigit())
            .foregroundStyle(Palette.Map.graticuleLabel)
    }

    /// Which way is up. Cheap, and the first question anyone asks of a map
    /// with no landmarks on it.
    private func drawNorthArrow(in context: inout GraphicsContext, size: CGSize) {
        // TOP RIGHT, and both parts of that are forced.
        //
        // It used to sit at (20, 78): x:20 to tuck into the corner, y:78 to
        // duck under the location card, which at y:20 covered it completely
        // and left the arrow drawn and invisible. Now that the whole drawing
        // is inset below the card there is nothing to duck, so the vertical
        // dodge is gone.
        //
        // The horizontal one flipped instead. LATITUDE labels run down the
        // left edge — that is where they belong, beside the lines they name —
        // and at x:20 the arrow sat in the middle of them, with "43.16°"
        // struck through by it. The right edge carries only the longitude
        // labels along the bottom, so it is the one margin with room.
        let origin = CGPoint(x: size.width - 22, y: 20)
        var arrow = Path()
        arrow.move(to: CGPoint(x: origin.x, y: origin.y))
        arrow.addLine(to: CGPoint(x: origin.x - 5, y: origin.y + 12))
        arrow.addLine(to: CGPoint(x: origin.x, y: origin.y + 8))
        arrow.addLine(to: CGPoint(x: origin.x + 5, y: origin.y + 12))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Palette.Map.graticuleLabel))
        context.draw(
            Text("С").font(.system(size: chromeSize, weight: .semibold))
                .foregroundStyle(Palette.Map.graticuleLabel),
            at: CGPoint(x: origin.x, y: origin.y + 22)
        )
    }

    /// The largest round step that still puts at least three lines across the
    /// span. Round in DEGREES rather than pixels, so the labels are numbers a
    /// person can read off a GPS rather than arbitrary fractions.
    static func graticuleStep(forSpan span: Double, minimumLines: Int = 3) -> Double {
        let candidates: [Double] = [1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005]
        for candidate in candidates where span / candidate >= Double(minimumLines) {
            return candidate
        }
        return candidates.last ?? 0.0005
    }

    /// Multiples of `step` inside the range. Indexed rather than accumulated,
    /// because repeatedly adding 0.02 drifts and the lines stop landing on
    /// the values the labels claim.
    static func gridValues(from low: Double, to high: Double, step: Double) -> [Double] {
        guard step > 0, high > low else { return [] }
        let first = (low / step).rounded(.up)
        let last = (high / step).rounded(.down)
        guard last >= first, last - first < 200 else { return [] }
        return stride(from: Int(first), through: Int(last), by: 1).map { Double($0) * step }
    }

    static func formatDegrees(_ value: Double, step: Double) -> String {
        let decimals = max(0, Int(ceil(-log10(step))))
        return String(format: "%.\(decimals)f°", value)
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
                .font(.system(size: labelSize, weight: .semibold))
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

