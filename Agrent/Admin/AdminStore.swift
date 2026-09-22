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

    private(set) var busy: Set<String> = []
    private(set) var writeError: String?
    private(set) var writeUnknown: String?

    /// Deactivating the LAST owner is refused server-side and counted
    /// live, with a database trigger behind it. Counted here too so the
    /// control is absent rather than present-and-refused.
    func isLastOwner(_ member: Membership) -> Bool {
        guard member.role == .owner, member.status == .active else { return false }
        return (members.value ?? [])
            .filter { $0.role == .owner && $0.status == .active }
            .count <= 1
    }

    /// ── SELF-DEACTIVATION IS NOT GUARDED HERE, and that is a gap I am
    ///    naming rather than papering over ──
    ///
    /// The server refuses it (`assertNotSelfDeactivation`), so it cannot
    /// happen — but a 403 after the tap is a worse way to learn it than a
    /// control that was never offered.
    ///
    /// Guarding it needs the current user's id, and THIS APP DOES NOT
    /// KNOW IT. There is no `/me` call and nothing stores one; the only
    /// place it exists client-side is inside the access token, and
    /// reading it would mean guessing which claim carries it. Guessing at
    /// a contract is what this codebase has been bitten by all day, and
    /// doing it to an auth token to save one error message is the worst
    /// trade available.
    ///
    /// So the server's refusal is rendered instead, and the gap is
    /// written down.
    func setActive(_ member: Membership, active: Bool) async {
        guard !busy.contains(member.id) else { return }
        busy.insert(member.id)
        writeError = nil
        writeUnknown = nil
        defer { busy.remove(member.id) }

        do {
            _ = try await AdminAPI.setActive(member.id, active: active)
            await load()
        } catch let error as URLError {
            // NEVER RE-SENT. The lookup filters `status: 'ACTIVE'`, so a
            // replay of a deactivation that already landed returns 404
            // "not found or not active" — a successful write whose retry
            // reports failure. The LIST is the authority on whether it
            // landed, so re-read it and let the operator see the answer.
            writeUnknown = UserMessage.text(for: error)
            await load()
        } catch {
            writeError = UserMessage.text(for: error)
        }
    }

    /// SAFE TO RETRY — `@@unique([tenantId, email])` and the usecase
    /// writes through it, so re-inviting upserts rather than creating a
    /// second row. The only cost of a replay is a second email.
    func invite(email: String, role: MembershipRole) async throws {
        _ = try await AdminAPI.invite(email: email, role: role)
        await load()
    }

    #if DEBUG
    /// Tests only. The last-owner guard is pure logic over a loaded list,
    /// and exercising it should not need a network.
    func setMembersForTesting(_ rows: [Membership]) {
        members = .loaded(rows, .fresh)
    }
    #endif

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
