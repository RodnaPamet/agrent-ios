import Foundation
import Observation

/// Which index is drawn over the imagery, and when its URL was minted.
@Observable
@MainActor
final class SatelliteIndexStore {
    /// nil = no overlay, plain imagery. THE DEFAULT.
    ///
    /// Same reasoning as the schematic default one level up: the overlay is
    /// the deliberate second look. Opening a parcel should not spend a
    /// round trip and a screenful of tiles on a question the farmer has not
    /// asked yet, and on a field with no signal it should not open onto a
    /// spinner.
    private(set) var selected: VegetationIndex?

    private(set) var tiles: IndexTiles?
    private(set) var isLoading = false
    private(set) var failure: String?

    /// nil until the first request answers. The buttons stay hidden while it
    /// is nil AND when it is false — "we do not know yet" and "not set up
    /// here" should both look like nothing, not like a disabled control the
    /// farmer will press twice.
    private(set) var isConfigured: Bool?

    private let locationID: String
    private var mintedAt: Date?

    init(locationID: String) { self.locationID = locationID }

    /// Well inside the server's six-hour window, so a refetch is cheap and
    /// served from its cache; far enough out that panning around a field for
    /// ten minutes does not re-request anything.
    private let staleAfter: TimeInterval = 60 * 60

    var isStale: Bool {
        guard let mintedAt else { return true }
        return Date().timeIntervalSince(mintedAt) > staleAfter
    }

    func select(_ index: VegetationIndex?) async {
        guard index != selected else { return }
        selected = index
        tiles = nil
        failure = nil
        mintedAt = nil
        guard let index else { return }
        await fetch(index)
    }

    /// Called when the satellite map appears. Re-requests an overlay that has
    /// been on screen long enough for its URL to be worth doubting; does
    /// nothing at all when no overlay is chosen.
    func refreshIfNeeded() async {
        guard let selected, isStale || tiles == nil else { return }
        await fetch(selected)
    }

    private func fetch(_ index: VegetationIndex) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await AgroAPI.tiles(index, locationID: locationID)
            // A racing selection change must not be overwritten by an
            // in-flight answer for the index the farmer just left.
            guard selected == index else { return }
            isConfigured = result.configured
            if result.isUsable {
                tiles = result
                mintedAt = Date()
            } else {
                // configured:false is NOT a failure. Leaving `failure` nil
                // means the UI hides the control rather than accusing the
                // network of something the deployment simply has not set up.
                tiles = nil
                selected = result.configured ? selected : nil
            }
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    /// The acquisition date, formatted, or nil when there is nothing drawn.
    ///
    /// This is rendered wherever the overlay is. The composite reaches
    /// backwards past cloud cover without saying so anywhere else, and an
    /// undated false-colour field is indistinguishable from a current one.
    var acquisitionDate: Date? {
        tiles?.date.flatMap(BgDate.parseISODay)
    }
}
