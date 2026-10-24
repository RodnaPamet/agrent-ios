import Foundation
import Observation

/// The blocks a treatment covers, with their parcels, for «Коригирай»'s
/// parcel list (#432; agri-saas #2304).
///
/// A correction may add a parcel only in a block the treatment already has:
/// the ДНЕВНИК prints one table per block, so a parcel of another block is a
/// treatment never recorded, and the server refuses it
/// (`TREATMENT_CORRECTION_NEW_BLOCK`). So only those blocks are read, by the
/// ids on the definition's own lines, and nothing from another block is
/// offered.
///
/// Each parcel's own area comes from the same read. «Целият парцел» can then
/// show its size, and an area larger than the parcel is said before the PUT
/// (`TREATMENT_AREA_EXCEEDS_PARCEL`).
@MainActor
@Observable
final class TreatmentBlocks {
    struct Block: Equatable, Sendable, Identifiable {
        let id: String
        /// Nil when `/locations` didn't name it: the list says «Блок».
        let name: String?
        let parcels: [Parcel]
    }

    /// In the order the definition's lines first name each block.
    private(set) var blocks: [Block] = []
    /// A read that failed: the parcels as recorded stay correctable, and
    /// nothing can be added. Said under the list.
    private(set) var failed = false

    /// From the server, not the cache: a correction needs the server anyway,
    /// and a parcel added on the web since the last map read should be there.
    func load(blockIDs: [String]) async {
        failed = false
        let names = (try? await LocationsAPI.decodeList(from: APIClient.shared.data(for: LocationsAPI.listPath)))
            .map { Dictionary($0.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        var read: [Block] = []
        for id in blockIDs {
            do {
                let parcels = try await LocationsAPI.decodeParcels(
                    from: APIClient.shared.data(for: LocationsAPI.parcelsPath(id))).parcels
                read.append(Block(id: id, name: names[id], parcels: parcels))
            } catch {
                failed = true
            }
        }
        blocks = read
    }
}
