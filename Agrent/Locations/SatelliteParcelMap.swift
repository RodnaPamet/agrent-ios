import MapKit
import SwiftUI

/// The satellite map, behind `MKMapView` rather than SwiftUI's `Map`.
///
/// ── Why this replaced a four-line SwiftUI `Map` ──
///
/// SwiftUI's MapKit has `MapPolygon`, `MapCircle` and friends, and no tile
/// overlay of any kind. There is no `MapTileOverlay`, and `MKTileOverlay`
/// cannot be reached through `MapContentBuilder`. Raster imagery from
/// somewhere other than Apple means an `MKMapView`, so the satellite branch
/// moves down a layer and the schematic branch — which is pure Canvas and
/// touches no MapKit at all, deliberately — is untouched by this.
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
    let parcels: [Parcel]
    let region: MKCoordinateRegion

    /// The XYZ template, or nil for imagery alone.
    let tileTemplate: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.mapType = .hybrid
        view.pointOfInterestFilter = .excludingAll
        view.showsCompass = false
        // The camera is set HERE and nowhere else. See updateUIView.
        view.setRegion(region, animated: false)

        for parcel in parcels {
            for polygon in parcel.geometry?.mapPolygons ?? [] {
                view.addOverlay(polygon, level: .aboveLabels)
            }
        }
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        // THE CAMERA IS NOT TOUCHED HERE.
        //
        // `updateUIView` runs on every state change, including each index
        // selection. Calling setRegion in it would throw the farmer back to
        // the whole-farm view every time they switched index — so the one
        // gesture the screen exists for, zooming into a patch and comparing
        // NDVI against NDMI over it, would undo itself on each tap.
        context.coordinator.syncTiles(to: tileTemplate, in: view)

        // Solid fills hide the data underneath them, so a parcel is filled
        // only when there is nothing to hide. The outline stays either way.
        context.coordinator.hasOverlay = tileTemplate != nil
        for overlay in view.overlays where overlay is MKPolygon {
            if let renderer = view.renderer(for: overlay) as? MKPolygonRenderer {
                renderer.fillColor = context.coordinator.polygonFill
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
        var hasOverlay = false

        var polygonFill: UIColor {
            hasOverlay ? .clear : UIColor.systemGreen.withAlphaComponent(0.35)
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
                renderer.fillColor = polygonFill
                renderer.strokeColor = .systemGreen
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
