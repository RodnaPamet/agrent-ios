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

    /// Whether THIS reader may edit the farm profile.
    ///
    /// Derived from the GET, not from a role. GET and PUT sit behind the same
    /// `requirePermission('admin.manage')` (OWNER and ADMIN), so a profile the
    /// server would show is a profile it would take a write for — and a 403
    /// on the read is a 403 on the write. Asking `/me` for a role and mapping
    /// it here would be a second copy of the server's permission table, which
    /// is the copy that drifts.
    private(set) var canEditProfile = false

    /// What the last save changed, for the profile page to say once.
    /// nil until a save lands; cleared when the profile page goes away so
    /// it does not outlive the screen it describes.
    private(set) var lastSaveNotes: [String]?

    /// A profile save that landed, for the profile page to play: the editor
    /// closes on success, so the page under it is what is on screen. Only
    /// `saveProfile` changes it — never a load or the reload after a 409.
    /// The editor plays its own refusals. See `WriteFeedback`.
    private(set) var profileSaveFeedback = WriteFeedback()

    /// The farm-profile network, as two closures so the lock is a unit test.
    ///
    /// There is no URLProtocol seam in `Tests/`, and the things worth pinning
    /// — which version goes out as `If-Match`, that a 409 is not a save, that
    /// the NEXT save carries the version the server returned — are all
    /// decided here, above the wire. Defaulted to the real routes; only tests
    /// pass anything else, and nothing in the suite sends the PUT.
    private let sendProfile: (FarmProfileUpdate) async throws -> FarmProfile
    private let fetchProfile: () async throws -> FarmProfile

    init(
        sendProfile: @escaping (FarmProfileUpdate) async throws -> FarmProfile
            = AdminAPI.saveFarmProfile,
        fetchProfile: @escaping () async throws -> FarmProfile
            = AdminAPI.fetchFarmProfile
    ) {
        self.sendProfile = sendProfile
        self.fetchProfile = fetchProfile
    }

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
            profile = .loaded(try await fetchProfile(), .fresh)
            canEditProfile = true
        } catch {
            // OFF ON ANY FAILURE, and the 403 branch below is why it matters:
            // it substitutes an all-null profile so the section reads «още не
            // са попълнени». An editor opened on THAT would read-modify-write
            // thirteen nulls over the real record. The editor only ever starts
            // from a profile the server actually sent.
            canEditProfile = false
            // A 403 here is already carried by `access`; do not also show a
            // second failure for the same cause.
            if AdminAPI.isForbidden(error) {
                // An EMPTY profile, not a failure — `isEmpty` is true of this,
                // so the section says «още не са попълнени» rather than
                // repeating a refusal the screen already shows.
                profile = .loaded(
                    FarmProfile(producerName: nil, eik: nil, egn: nil, address: nil,
                                settlement: nil, municipality: nil,
                                registrationPlace: nil, registrationEkatte: nil,
                                odbhCity: nil, agricultureDirectorateCity: nil,
                                urn: nil, sizeHa: nil, grainProduced: []),
                    .fresh)
            } else {
                profile = .failed(UserMessage.text(for: error))
            }
        }
    }

    /// Save the WHOLE profile and show what the server stored.
    ///
    /// `body` comes from `FarmProfileUpdate.build`: read-modify-write over the
    /// profile the editor opened on, carrying THAT profile's version as
    /// `expectedVersion` — the `If-Match`. Not `profile.value?.version`,
    /// which a refresh behind the sheet may have moved on.
    ///
    /// THE RESPONSE REPLACES THE SCREEN, not the draft. The server trims,
    /// sanitises and de-duplicates, so the submitted values are not
    /// necessarily the stored ones; keeping them would show a profile the
    /// database does not hold. Same rule the web's save follows. It also
    /// carries the NEW version, and because the next editor opens on
    /// `profile.value`, the next save sends it with no re-GET.
    ///
    /// Throws for the sheet to show and stay open. A 409 throws
    /// `APIError.conflict` and leaves `profile` UNTOUCHED: nothing was saved,
    /// and the sheet — not this — decides whether to reload.
    ///
    /// `eikVerification` included, AS SENT. Until agri-saas #1375 the PUT
    /// answered `project(row)` with no status, which defaulted to `NONE`, and
    /// this carried the status held before the save over it (agri-saas#1358,
    /// agrent-ios#172). Since #1375 (live 2026-10-08) the status is a
    /// required argument and the PUT derives it as the GET does, on the
    /// write path and the no-op path alike — so the PUT's is the freshest
    /// there is, and keeping the old one would hide a verification that
    /// landed while the page was open.
    func saveProfile(_ body: FarmProfileUpdate, typed draft: FarmProfileDraft) async throws {
        let saved = try await sendProfile(body)
        profile = .loaded(saved, .fresh)
        lastSaveNotes = FarmProfileSaveReport.notes(draft: draft, saved: saved)
        profileSaveFeedback.saved()
    }

    /// Re-read the profile after a 409, for the editor to rebase onto.
    ///
    /// Updates the screen behind the sheet as well, so cancelling out of the
    /// editor afterwards shows what is stored now rather than what was
    /// stale. Throws to the sheet: a failed reload must not look like one
    /// that brought back nothing new.
    func reloadProfile() async throws -> FarmProfile {
        let fresh = try await fetchProfile()
        profile = .loaded(fresh, .fresh)
        return fresh
    }

    func clearSaveNotes() { lastSaveNotes = nil }

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

    func setProfileForTesting(_ value: FarmProfile, editable: Bool) {
        profile = .loaded(value, .fresh)
        canEditProfile = editable
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
