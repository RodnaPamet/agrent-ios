import CoreLocation

/// Where «Времето» is asked about (#642): a point and the words for it.
struct WeatherPoint: Identifiable, Equatable {
    let place: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(latitude),\(longitude)" }

    /// The parcel under the point, «Парцел 15655-19, Ivo's Land»; otherwise
    /// «Ivo's Land, центъра на картата».
    static func place(at point: CLLocationCoordinate2D, parcels: [Parcel], block: String) -> String {
        if let parcel = parcels.first(where: { $0.geometry?.contains(point) == true }) {
            return "\(parcel.name), \(block)"
        }
        return "\(block), центъра на картата"
    }
}
