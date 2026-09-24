import MapKit
import SwiftUI

/// The satellite map, behind `MKMapView` rather than SwiftUI's `Map`.
///
/// ── Why this replaced a four-line SwiftUI `Map` ──
///
/// SwiftUI's MapKit has `MapPolygon`, `MapCircle` and friends, and no tile
/// overlay of any kind. There is no `MapTileOverlay`, and `MKTileOverlay`
/// cannot be reached through `MapContentBuilder`. Raster imagery from
/// somewhere other than Apple means an `MKMapView`, so the map moved down a
/// layer. It now serves BOTH modes the toggle offers — true outlines with
/// index tiles, and simplified rectangles coloured sown or fallow — because
/// a second representable in an if/else would tear this view down on every
/// switch. See `ParcelShape`.
///
/// ── Overlay order is the whole design ──
///
/// Three layers, bottom to top: Apple's hybrid imagery, the index tiles, the
/// parcel outlines. The tiles go in at `.aboveRoads` and the outlines at
/// `.aboveLabels`, which is not decoration — an operator has to see WHICH
/// field a colour belongs to, and an index tile painted over its own boundary
/// makes a five-hectare block of dark red that could be either of two
/// parcels. Level, not insertion order, because MapKit is free to reorder
/// within a level.
struct SatelliteParcelMap: UIViewRepresentable {
    /// What a parcel is drawn AS.
    ///
    /// Two modes on one `MKMapView`, not two views: a second
    /// `UIViewRepresentable` in an `if`/`else` gives SwiftUI different
    /// structural identity, which tears the map view down, re-runs
    /// `makeUIView` and re-fires the index refresh on every toggle. A
    /// property costs one overlay remount instead.
    enum ParcelShape {
        /// The true GeoJSON outline, holes and all.
        case outlines
        /// One rectangle per parcel — `ParcelGeometry.boundingMapPolygon`.
        case boundingBoxes
    }

    let parcels: [Parcel]
    let region: MKCoordinateRegion

    /// The XYZ template, or nil for imagery alone.
    let tileTemplate: String?

    var shape: ParcelShape = .outlines

    /// Passed in rather than read from the environment, because this is a
    /// `UIViewRepresentable` and MapKit's renderers are not SwiftUI views —
    /// nothing inside the coordinator would ever be re-evaluated when the
    /// setting changes. See `Palette.Map.fillOpacity(_:)`: on the simplified
    /// map the fill IS the data, which is the case that setting exists for.
    var contrast: ColorSchemeContrast = .standard

    /// A camera move to make ONCE.
    ///
    /// A COUNTER, not a region comparison, and the difference is the feature.
    /// Pressing the target button again after panning away sends the same
    /// region and must still move; on a one-parcel farm every press sends the
    /// identical region and each one is a deliberate recentre. Comparing
    /// regions would make both of those do nothing.
    struct CameraCommand {
        let tick: Int
        let region: MKCoordinateRegion
    }

    var camera: CameraCommand?

    /// nil when the signed-in member may not create operations — see
    /// `CurrentUser.mayCreateOperations`, which fails open. Passing nil
    /// removes the gesture rather than swallowing the tap, so a map that
    /// cannot act does not absorb touches pretending it might.
    var onTap: ((Parcel) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.mapType = .hybrid
        view.pointOfInterestFilter = .excludingAll
        view.showsCompass = false
        // The opening camera is `region`, and a command that arrived before
        // this view existed is DISCARDED rather than honoured.
        //
        // Honouring it was wrong in a way that stuck. The mode button lives
        // on the screen's own toolbar, outside the `switch store.state`, so
        // it is live while the parcels are still loading. Pressed then,
        // `mapRegion` finds no response, no drawable parcels, and falls back
        // to the location's bounds or — where the server sent none, which is
        // one field away on this tenant — to `.bulgaria`, 3.6° by 7.5°. That
        // command then beat the `region` computed from the loaded response,
        // AND was seeded as applied, so `region` was never honoured again
        // and the farm opened on a view of the whole country until something
        // else moved the camera.
        //
        // Seeding the tick without obeying the command keeps the other half
        // of the bargain: the stale command cannot replay as a second jump
        // either. `region` is computed fresh here from whatever state the
        // view is actually being built with, which is the better answer in
        // every case.
        view.setRegion(region, animated: false)
        context.coordinator.seed(camera?.tick)
        context.coordinator.shape = shape
        context.coordinator.contrast = contrast
        context.coordinator.syncParcels(parcels, shape: shape, in: view)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        // MKMapView zooms on double tap, and a single-tap recogniser fires
        // on the first of the two. Without this, double-tapping to zoom in
        // on a field opens the spray sheet on the way.
        for existing in view.gestureRecognizers ?? [] {
            if let other = existing as? UITapGestureRecognizer,
               other.numberOfTapsRequired == 2 {
                tap.require(toFail: other)
            }
        }
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        // THE CAMERA IS NOT MOVED BY `region`, AND NEVER WILL BE.
        //
        // `updateUIView` runs on every state change, including each index
        // selection. Honouring `region` here would throw the farmer back to
        // the whole-farm view every time they switched index — so the one
        // gesture the screen exists for, zooming into a patch and comparing
        // NDVI against NDMI over it, would undo itself on each tap.
        //
        // `camera` is the deliberate exception, and is why it carries a tick:
        // it moves the map when, and only when, something asked it to.
        context.coordinator.onTap = onTap
        // The gesture is removed rather than made a no-op, so the map does
        // not consume a touch it will do nothing with.
        context.coordinator.tap?.isEnabled = onTap != nil

        context.coordinator.shape = shape
        context.coordinator.contrast = contrast
        // Solid fills hide the data underneath them, so a parcel is filled
        // only when there is nothing to hide. The outline stays either way.
        context.coordinator.hasOverlay = tileTemplate != nil

        context.coordinator.syncParcels(parcels, shape: shape, in: view)
        context.coordinator.syncTiles(to: tileTemplate, in: view)
        context.coordinator.apply(camera, in: view)

        // Repaint what MapKit has already drawn. `renderer(for:)` returns nil
        // for anything not yet on screen, which is fine — those get their
        // style from `rendererFor` when they are first drawn. Both routes go
        // through the same `style` call so they cannot drift apart.
        for overlay in view.overlays where overlay is MKPolygon {
            if let polygon = overlay as? MKPolygon,
               let renderer = view.renderer(for: overlay) as? MKPolygonRenderer {
                context.coordinator.style(renderer, for: polygon)
                renderer.setNeedsDisplay()
            }
        }
    }

    /// MapKit holds the renderers; SwiftUI rebuilds the struct. Anything that
    /// must survive a rebuild — the template currently mounted, so identical
    /// updates do not tear down a loaded tile layer — lives here.
    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var mountedTemplate: String?
        private var mountedParcels: [Parcel] = []
        private var mountedShape: ParcelShape?
        private var appliedTick = 0

        /// Which parcel each `MKPolygon` came from. One parcel can produce
        /// several — `15655-19` is one polygon with five rings — and MapKit
        /// hands the delegate the overlay, not the model, so the way back
        /// has to be kept here.
        private var owners: [ObjectIdentifier: Parcel] = [:]

        var hasOverlay = false
        var shape: ParcelShape = .outlines
        var contrast: ColorSchemeContrast = .standard
        var onTap: ((Parcel) -> Void)?
        weak var tap: UITapGestureRecognizer?

        /// Whether the overlays on screen still describe the data.
        ///
        /// COMPARES THE PARCELS THEMSELVES, not their ids, and this went
        /// wrong twice in the same guard.
        ///
        /// First it compared ids alone, which are identical in both shapes —
        /// same fields, drawn differently — so switching mode returned early
        /// and left the old overlays mounted. A control that changes nothing
        /// is indistinguishable from a broken one.
        ///
        /// Then, with the shape folded in, ids were still all it knew about
        /// the parcels. `CachedResource.loadShowingCacheFirst` publishes
        /// TWICE by design — the cached copy, then the fresh one — and those
        /// two carry the same ids with different contents. A crop recorded
        /// on the web, or a corrected boundary, arrives in the second publish
        /// and was dropped: the simplified map would keep drawing a field
        /// fallow-dashed while the list directly beneath it, reading the same
        /// fresh response, named the crop.
        ///
        /// `Parcel`'s `==` is synthesised over every stored property,
        /// geometry included. Its `hash(into:)` is NOT — it is narrowed to
        /// `id` deliberately — so this must never become a hash comparison.
        static func needsRemount(
            _ parcels: [Parcel], _ shape: ParcelShape,
            mountedParcels: [Parcel], mountedShape: ParcelShape?
        ) -> Bool {
            shape != mountedShape || parcels != mountedParcels
        }

        /// Records a command as already honoured, without moving anything.
        func seed(_ tick: Int?) {
            appliedTick = tick ?? 0
        }

        /// The bookkeeping, split from the camera move so the rule can be
        /// tested — no test can drive an `MKMapView`'s camera, and both ways
        /// of getting this wrong are invisible in a code review.
        func consume(_ tick: Int) -> Bool {
            guard tick > appliedTick else { return false }
            appliedTick = tick
            return true
        }

        func apply(_ command: CameraCommand?, in view: MKMapView) {
            guard let command, consume(command.tick) else { return }
            // Instant under Reduce Motion. A camera flight across a farm is
            // precisely what someone turns that setting on to stop, and the
            // destination is the point rather than the journey.
            view.setRegion(command.region, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        func syncParcels(_ parcels: [Parcel], shape: ParcelShape, in view: MKMapView) {
            guard Self.needsRemount(parcels, shape,
                                    mountedParcels: mountedParcels,
                                    mountedShape: mountedShape) else { return }
            mountedParcels = parcels
            mountedShape = shape

            for overlay in view.overlays where overlay is MKPolygon {
                view.removeOverlay(overlay)
            }
            owners.removeAll()
            for parcel in parcels {
                for polygon in Self.polygons(for: parcel, shape: shape) {
                    owners[ObjectIdentifier(polygon)] = parcel
                    view.addOverlay(polygon, level: .aboveLabels)
                }
            }
        }

        /// One parcel's overlays. A box is ONE rectangle for the parcel, not
        /// one per polygon — the simplified map draws a field as a field.
        static func polygons(for parcel: Parcel, shape: ParcelShape) -> [MKPolygon] {
            switch shape {
            case .outlines:
                return parcel.geometry?.mapPolygons ?? []
            case .boundingBoxes:
                return [parcel.geometry?.boundingMapPolygon].compactMap { $0 }
            }
        }

        /// The one place a parcel's colours are decided.
        ///
        /// On OUTLINES the fill is uniform green over imagery, because the
        /// index tiles are the data there and a crop-coloured fill would
        /// argue with them.
        ///
        /// On BOXES there are no tiles, so sown against fallow is what the
        /// map has to say, in the schematic's own palette. The dash is the
        /// non-colour channel and is what keeps the distinction alive in a
        /// monochrome screenshot or for a red-green colour-blind operator —
        /// it is not decoration.
        func style(_ renderer: MKPolygonRenderer, for polygon: MKPolygon) {
            switch shape {
            case .outlines:
                renderer.fillColor = hasOverlay
                    ? .clear
                    : UIColor.systemGreen.withAlphaComponent(0.35)
                renderer.strokeColor = .systemGreen
                renderer.lineWidth = 2
                renderer.lineDashPattern = nil

            case .boundingBoxes:
                // Defaults to sown when the owner is unknown, which cannot
                // happen through `syncParcels` but would otherwise paint an
                // orphan overlay as fallow and assert something false.
                let sown = owners[ObjectIdentifier(polygon)]?.isSown ?? true
                let fill = sown ? Palette.Map.sownFill : Palette.Map.fallowFill
                let stroke = sown ? Palette.Map.sownStroke : Palette.Map.fallowStroke
                renderer.fillColor = UIColor(fill)
                    .withAlphaComponent(Palette.Map.fillOpacity(contrast))
                renderer.strokeColor = UIColor(stroke)
                renderer.lineWidth = Palette.Map.strokeWidth(contrast)
                renderer.lineDashPattern = sown
                    ? nil
                    : Palette.Map.dash.map { NSNumber(value: Double($0)) }
            }
        }

        /// Tap a field, open its operation sheet.
        ///
        /// Two things this does that a bounding-box test would not.
        ///
        /// HOLES COUNT. `MKPolygonRenderer` builds interior rings into the
        /// same `CGPath`, so an even-odd containment test treats them as
        /// outside — which is what they are. This is not hypothetical
        /// tidiness: the owner's `15655-19` is a single polygon with five
        /// rings, so four holes, across 32 hectares. Tapping one of them
        /// should select nothing, exactly as tapping the grass beside the
        /// field does.
        ///
        /// SMALLEST WINS. Where
        /// parcels overlap or nest, the small one is the one drawn on top
        /// and the one under the finger, so the tap has to resolve the way
        /// the eye does or an operator opens the parcel behind the one they
        /// can see.
        @objc func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let onTap, let view = recogniser.view as? MKMapView else { return }
            let coordinate = view.convert(recogniser.location(in: view), toCoordinateFrom: view)
            let mapPoint = MKMapPoint(coordinate)

            var hit: (parcel: Parcel, area: Double)?
            for overlay in view.overlays {
                guard let polygon = overlay as? MKPolygon,
                      let parcel = owners[ObjectIdentifier(polygon)],
                      polygon.boundingMapRect.contains(mapPoint),
                      let renderer = view.renderer(for: polygon) as? MKPolygonRenderer
                else { continue }

                // The path is built lazily and is nil until something has
                // drawn — including for a polygon scrolled off screen.
                if renderer.path == nil { renderer.createPath() }
                guard let path = renderer.path,
                      path.contains(renderer.point(for: mapPoint), using: .evenOdd)
                else { continue }

                let rect = polygon.boundingMapRect
                let area = rect.size.width * rect.size.height
                if hit == nil || area < hit!.area { hit = (parcel, area) }
            }
            if let hit { onTap(hit.parcel) }
        }

        func syncTiles(to template: String?, in view: MKMapView) {
            guard template != mountedTemplate else { return }
            mountedTemplate = template

            for overlay in view.overlays where overlay is MKTileOverlay {
                view.removeOverlay(overlay)
            }
            guard let template else { return }

            let overlay = MKTileOverlay(urlTemplate: template)
            // FALSE, and this is the one that would be silently wrong.
            //
            // `true` tells MapKit these tiles ARE the map and it may stop
            // drawing its own. Earth Engine clips each tile to the parcel
            // geometry, so everything outside a field is transparent — and
            // with `true` that transparency becomes a black void where the
            // farm's surroundings should be. The imagery has to stay under
            // it for the overlay to read as data about a place.
            overlay.canReplaceMapContent = false
            view.addOverlay(overlay, level: .aboveRoads)
        }

        func mapView(_ view: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                // 0.7, because that is what the web draws.
                //
                // This was 1.0, argued from "the same colour must mean the
                // same number on both clients" — which is the right
                // principle and I applied it backwards. MapCanvas.tsx sets
                // `raster-opacity: 0.7`, so the blended colour IS the one
                // the owner sees on a laptop; rendering opaque here would
                // make the phone the odd instrument out, for the exact
                // reason I gave for not doing it.
                //
                // Both clients therefore show a ramp slightly muted against
                // a full-opacity legend. That is a shared imprecision rather
                // than a divergence, and a farmer comparing two screens over
                // one field gets the same answer from both.
                renderer.alpha = 0.7
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                style(renderer, for: polygon)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
