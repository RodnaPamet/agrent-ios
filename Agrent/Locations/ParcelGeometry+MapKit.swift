import MapKit

extension ParcelGeometry {
    /// THE ONE PLACE THE AXES CROSS, and the only place they should.
    ///
    /// GeoJSON orders a position `[longitude, latitude]`.
    /// `CLLocationCoordinate2D` takes `latitude` FIRST. Getting it backwards
    /// is silent in every way that matters: no crash, no warning, and a
    /// perfectly well-formed polygon — drawn in the Red Sea, because a farm at
    /// 43°N 24°E becomes a shape at 24°N 43°E.
    ///
    /// Every conversion in the app goes through here so there is exactly one
    /// line to get right, and a test asserts the RESULT lands inside Bulgaria
    /// rather than asserting that the code says what it says.
    static func coordinate(from point: [Double]) -> CLLocationCoordinate2D? {
        guard point.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
    }

    /// One `MKPolygon` per GeoJSON polygon, with ring 0 as the outline and
    /// every further ring as an interior hole.
    ///
    /// Flattening the rings into a single polygon instead would draw the holes
    /// as solid land. That is not a theoretical concern: the owner's parcel
    /// `15655-19` is one polygon with five rings, so four holes, across 32
    /// hectares.
    ///
    /// A ring with fewer than three points is dropped rather than passed to
    /// MapKit — degenerate geometry should cost one shape, not the map.
    var mapPolygons: [MKPolygon] {
        coordinates.compactMap { polygon -> MKPolygon? in
            guard let outerRing = polygon.first else { return nil }
            let outer = outerRing.compactMap(Self.coordinate(from:))
            guard outer.count >= 3 else { return nil }

            let holes = polygon.dropFirst().compactMap { ring -> MKPolygon? in
                let points = ring.compactMap(Self.coordinate(from:))
                guard points.count >= 3 else { return nil }
                return MKPolygon(coordinates: points, count: points.count)
            }

            return MKPolygon(
                coordinates: outer,
                count: outer.count,
                interiorPolygons: holes.isEmpty ? nil : holes
            )
        }
    }
}

extension BoundingBox {
    /// The camera, built from named fields rather than array positions.
    ///
    /// Fed `[minLon, minLat, maxLon, maxLat]` positionally, an
    /// `MKCoordinateRegion` centres near 24°N 43°E and the parcels are simply
    /// off-screen — which reads as "this farm has no fields" rather than as a
    /// bug, and is therefore worse than drawing them in the wrong place.
    ///
    /// Padded so boundaries are not flush against the edge, and floored so a
    /// single small parcel does not zoom to street level.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(
                latitudeDelta: max(latSpan * 1.25, 0.005),
                longitudeDelta: max(lonSpan * 1.25, 0.005)
            )
        )
    }
}

extension MKCoordinateRegion {
    /// Bulgaria, as the last resort — NOT the world.
    ///
    /// `MKCoordinateRegion(.world)` was the terminal fallback here. The web
    /// hit the same thing and fixed it: `MapCanvas.tsx` defines
    /// `BULGARIA_VIEW` at 42.73N 25.49E with a comment reading "approx.
    /// geographic centre, not the world". Same centre constant here so the
    /// two clients frame an empty location identically.
    ///
    /// The span is not the web's `zoom: 6.4`, because a zoom level is a
    /// function of viewport width and does not transfer — a phone at 6.4
    /// would show about 3° of longitude, which is half the country. This is
    /// the country's own extent plus a margin, which is what that zoom is
    /// FOR on a desktop viewport.
    ///
    /// It matters because `boundsJson` is derived from a spatial import, so
    /// a location with no shapefile and no parcel geometry has null bounds
    /// correctly rather than by omission — and one of this tenant's two
    /// locations is exactly that. There is nothing to derive a camera from,
    /// so the question is only which wrong-but-harmless view to show, and
    /// "somewhere in Bulgaria" beats "the planet".
    static let bulgaria = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.73, longitude: 25.49),
        span: MKCoordinateSpan(latitudeDelta: 3.6, longitudeDelta: 7.5)
    )

    /// A camera that fits the parcels themselves.
    ///
    /// The satellite branch used to read `response.bounds ?? location.boundsJson`
    /// and fall back to `MKCoordinateRegion(.world)`. Both of those are
    /// optional on the wire and one of this tenant's two locations returns
    /// NEITHER — so the fallback is not hypothetical, it is one server field
    /// away, and what it does is open the map on the whole planet. A farmer
    /// would read that as "my fields are gone".
    ///
    /// Geometry is the better source anyway: it is the thing being drawn, so
    /// a camera derived from it cannot disagree with what is on screen, and
    /// it exists whenever there is anything to show. Server bounds stay
    /// first — they are what the web uses, so the two clients open on the
    /// same view — and this sits between them and `.bulgaria`.
    ///
    /// Note what this canNOT fix: the location with null bounds has null
    /// bounds *because* it has no geometry, so it falls past this too. The
    /// two fallbacks answer different failures — stale or missing bounds
    /// over real fields, and no spatial data at all.
    init?(fitting parcels: [Parcel]) {
        var lats: [Double] = [], lons: [Double] = []
        for parcel in parcels {
            for polygon in parcel.geometry?.coordinates ?? [] {
                for ring in polygon {
                    for point in ring where point.count >= 2 {
                        lons.append(point[0])
                        lats.append(point[1])
                    }
                }
            }
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }

        // Same padding and floor as BoundingBox.region, so switching source
        // does not also switch how tight the camera is.
        self.init(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.25, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.25, 0.005)
            )
        )
    }
}
