import Foundation
import Observation

/// The admin screen's data, with "you are not allowed here" as a FIRST-CLASS
/// state rather than an error.
@Observable
@MainActor
final class AdminStore {
    enum Access: Equatable {
        case allowed
        /// A READER opened this screen. Real accounts have this role.
        case forbidden
    }

    private(set) var access: Access = .allowed
    private(set) var members: LoadState<[Membership]> = .loading
    private(set) var profile: LoadState<FarmProfile> = .loading

    func load() async {
        async let m: Void = loadMembers()
        async let p: Void = loadProfile()
        _ = await (m, p)
    }

    private func loadMembers() async {
        if members.value == nil { members = .loading }

        // Not through `CachedResource`. Two reasons, and the second is the
        // one that decides it:
        //
        // 1. This screen is used at a desk, not in a field. The offline
        //    read that justifies caching everywhere else is not the case
        //    here — nobody manages access with no signal.
        // 2. The payload is a list of colleagues' names and email
        //    addresses. `ResponseCache` writes raw bytes, so caching it
        //    puts a staff directory on the device's disk to save a round
        //    trip nobody needed. Not modelling a field would not prevent
        //    that; declining to cache is what prevents it.
        do {
            let data = try await APIClient.shared.data(for: AdminAPI.membersPath)
            members = .loaded(try await AdminAPI.decodeMembers(from: data), .fresh)
            access = .allowed
        } catch {
            if AdminAPI.isForbidden(error) {
                access = .forbidden
                members = .loaded([], .fresh)
            } else {
                members = .failed(UserMessage.text(for: error))
            }
        }
    }

    private func loadProfile() async {
        if profile.value == nil { profile = .loading }
        do {
            let data = try await APIClient.shared.data(for: AdminAPI.farmProfilePath)
            profile = .loaded(try await AdminAPI.decodeFarmProfile(from: data), .fresh)
        } catch {
            // A 403 here is already carried by `access`; do not also show a
            // second failure for the same cause.
            if AdminAPI.isForbidden(error) {
                profile = .loaded(
                    FarmProfile(producerName: nil, eik: nil, egn: nil, address: nil,
                                settlement: nil, municipality: nil,
                                registrationPlace: nil, registrationEkatte: nil,
                                odbhCity: nil, agricultureDirectorateCity: nil),
                    .fresh)
            } else {
                profile = .failed(UserMessage.text(for: error))
            }
        }
    }

    /// Grouped for display, in the order the questions get asked:
    /// who is waiting, who is here, who used to be.
    func grouped(_ all: [Membership]) -> [(MembershipStatus, [Membership])] {
        // The order the questions get asked: who is waiting, who is here,
        // who used to be, who is gone. `removed` last because it is the
        // only terminal one.
        let order: [MembershipStatus] = [
            .invited, .active, .deactivated, .removed, .unknown,
        ]
        return order.compactMap { status in
            let rows = all.filter { $0.status == status }
            return rows.isEmpty ? nil : (status, rows)
        }
    }
}
