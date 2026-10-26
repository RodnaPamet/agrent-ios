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
///
/// An activity's correction (#447) reads its own blocks the same way, and
/// may then read any other of the farm's (`add`): pruning, cultivation and a
/// harvest aren't in the БАБХ register, so a new block is allowed (owner,
/// 2026-10-26).
@MainActor
@Observable
final class TreatmentBlocks {
    struct Block: Equatable, Sendable, Identifiable {
        let id: String
        /// Nil when `/locations` didn't name it: the list says «Блок».
        let name: String?
        let parcels: [Parcel]
    }

    /// In the order the definition's lines first name each block, then any
    /// added, in the order they were.
    private(set) var blocks: [Block] = []
    /// Every block of the farm, by name, from the same `/locations` read:
    /// what an activity's correction may add from.
    private(set) var farmBlocks: [Location] = []
    /// A block being read for `add`, so the list can say so.
    private(set) var adding: String?
    /// A read that failed: the parcels as recorded stay correctable, and
    /// nothing can be added. Said under the list.
    private(set) var failed = false

    /// From the server, not the cache: a correction needs the server anyway,
    /// and a parcel added on the web since the last map read should be there.
    func load(blockIDs: [String]) async {
        failed = false
        let list = (try? await LocationsAPI.decodeList(from: APIClient.shared.data(for: LocationsAPI.listPath))) ?? []
        farmBlocks = list
        let names = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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

    /// One more of the farm's blocks, read and appended. A failure leaves
    /// the list as it was and says so under it.
    func add(blockID: String) async {
        guard !blocks.contains(where: { $0.id == blockID }), adding == nil else { return }
        adding = blockID
        defer { adding = nil }
        do {
            let parcels = try await LocationsAPI.decodeParcels(
                from: APIClient.shared.data(for: LocationsAPI.parcelsPath(blockID))).parcels
            let name = farmBlocks.first { $0.id == blockID }?.name
            blocks.append(Block(id: blockID, name: name, parcels: parcels))
        } catch {
            failed = true
        }
    }
}
