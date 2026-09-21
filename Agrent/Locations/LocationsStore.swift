import Foundation
import Observation

@Observable
@MainActor
final class LocationsStore {
    private(set) var state: LoadState<[Location]> = .loading

    func load() async {
        if state.value == nil { state = .loading }
        state = await CachedResource.load(LocationsAPI.listPath) { data in
            try await LocationsAPI.decodeList(from: data)
        }
    }
}

@Observable
@MainActor
final class ParcelsStore {
    private(set) var state: LoadState<ParcelsResponse> = .loading
    private let locationID: String

    init(locationID: String) { self.locationID = locationID }

    func load() async {
        if state.value == nil { state = .loading }
        let path = LocationsAPI.parcelsPath(locationID)
        state = await CachedResource.load(path) { data in
            try await LocationsAPI.decodeParcels(from: data)
        }
    }
}
