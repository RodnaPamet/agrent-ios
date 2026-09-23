import Foundation

/// Pull the data a field needs BEFORE the field.
///
/// ── The gap this closes, found on a real phone ──
///
/// `ParcelOperationSheet` fetches products and rate units in its own
/// `.task`, when the sheet opens. `CachedResource` writes the cache only
/// after a successful fetch. So the catalogue a farmer needs to record a
/// spray was fetched at the exact moment they are least likely to have
/// signal — standing in a field with the sheet already open.
///
/// The offline outbox is worthless without this. A queued spray needs a
/// product chosen, and the picker was empty offline on a phone that had
/// never opened the sheet while online. Recording the work was impossible
/// before queueing it ever came up.
///
/// ── Why locations and parcels are here too ──
///
/// The first version warmed only products and units, on the argument that
/// "locations and parcels are already cached by ordinary navigation — you
/// cannot reach the sheet without passing through the screens that fetch
/// them."
///
/// That assumed a usage pattern rather than covering a case. It is true of
/// somebody who has used the app online for a while. It is false of a
/// fresh install, where signing in and going straight into a field means
/// nothing has ever been fetched — which is exactly what happened on the
/// owner's phone: Локации itself showed nothing, not just the products
/// inside it.
///
/// A farmer's first day is the worst day to discover the app only works
/// once you have already used it.
///
/// ── What is still NOT warmed, and why ──
///
/// Journal, tasks, exchange and prices are READ surfaces. Arriving at one
/// with no signal and no cache shows an empty state, which is
/// disappointing and honest. Arriving at the spray sheet that way makes a
/// record of regulated work impossible to take, which is not — so the
/// write path and everything it depends on is warmed, and the rest is
/// left to pay for itself on first use.
enum OfflinePrefetch {
    /// Fire and forget, on launch and on return to the foreground — the
    /// moments a phone most recently had signal.
    ///
    /// Failures are silent by design. This is opportunistic warming, not a
    /// screen: a farmer who is already offline when it runs gets nothing
    /// from it and must not be told about it.
    ///
    /// Sequential rather than concurrent. On a weak connection six
    /// parallel requests compete for the same scrap of bandwidth and all
    /// of them time out; one at a time, the early ones land.
    static func warm() async {
        // Who is signed in, so a cold launch in a field has it. Without
        // this the identity cache is written only by the launch task's own
        // call, which never succeeds if the first launch of the day is
        // already out of signal — and the spray sheet's save gate needs it.
        _ = await CachedResource.load(MeAPI.path) {
            try await MeAPI.decode(from: $0)
        }
        let locations = await CachedResource.load(LocationsAPI.listPath) {
            try await LocationsAPI.decodeList(from: $0)
        }
        // Parcels are per-location and the map cannot draw without them.
        for location in locations.value ?? [] {
            _ = await CachedResource.load(LocationsAPI.parcelsPath(location.id)) {
                try await LocationsAPI.decodeParcels(from: $0)
            }
        }
        _ = await CachedResource.load(LocationsAPI.itemsPath) {
            try await LocationsAPI.decodeItems(from: $0)
        }
        _ = await CachedResource.load(LocationsAPI.rateUnitsPath) {
            try await LocationsAPI.decodeUnits(from: $0)
        }
    }
}
