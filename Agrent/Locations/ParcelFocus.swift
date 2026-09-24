import Foundation

/// Which field the target button jumps to next.
///
/// Split out of the view because it is the only part of that button a test
/// can reach: the rest is a camera move inside `MKMapView`.
enum ParcelFocus {
    /// The next parcel after `id`, wrapping at the end.
    ///
    /// KEYED ON ID, NOT ON AN INDEX. The obvious implementation stores "we
    /// are on parcel 2" — and the list this walks is rebuilt on every load,
    /// which `ParcelsStore.load()` re-runs after every recorded operation.
    /// A stored index survives that and silently points at a different
    /// field, so pressing target after recording a spray would jump
    /// somewhere the farmer did not leave off. An id either still names a
    /// parcel or does not.
    ///
    /// An unknown id — the parcel it named is gone from the farm — restarts
    /// at the first rather than returning nil, because the button must keep
    /// working through a data change rather than go dead until the screen is
    /// reopened.
    ///
    /// With one parcel it returns that parcel, on every press. That is
    /// deliberate: the press recentres, which is a real thing to want after
    /// panning away, and a button that refuses is a promise this screen
    /// cannot keep.
    static func next(after id: String?, in parcels: [Parcel]) -> Parcel? {
        guard !parcels.isEmpty else { return nil }
        guard let id, let current = parcels.firstIndex(where: { $0.id == id }) else {
            return parcels.first
        }
        return parcels[(current + 1) % parcels.count]
    }

    /// "парцел 2 от 5" — said aloud, because the camera move is the entire
    /// effect of the press and `SatelliteParcelMap` builds no accessibility
    /// tree at all. Counted over the parcels being cycled, which are the
    /// DRAWABLE ones: a farm with ten parcels and three outlines cycles
    /// through three, and claiming "2 от 10" would describe a list the
    /// button does not walk.
    static func position(of parcel: Parcel, in parcels: [Parcel]) -> String? {
        guard let index = parcels.firstIndex(where: { $0.id == parcel.id }) else { return nil }
        return "парцел \(index + 1) от \(parcels.count)"
    }
}
