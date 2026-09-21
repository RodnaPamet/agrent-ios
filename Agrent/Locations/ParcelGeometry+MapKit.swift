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
