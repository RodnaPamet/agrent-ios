import Foundation

/// The parcel archive's writes and deletes.
///
/// ── `GET /history` is absent on purpose ──
///
/// The read route exists and is ETagged, and it is the part still moving: it
/// answers with the WHOLE archive on one request, and whether that gets a
/// bounded page is with the owner. Adding a fetch here now would pin the one
/// shape expected to change, and every screen built on it would be built on
/// the envelope rather than on the items. The item models are settled
/// (`ParcelHistoryModels`), so those came first.
///
/// ── Neither create is replay-safe ──
///
/// The generated spec documents `Idempotency-Key` on six writes and
/// documents its absence where absence bites. It says nothing about these
/// two. So: no key, no auto-retry, one write in flight per parcel, and a
/// timeout reported as UNKNOWN rather than as a failure — because telling an
/// operator a write failed invites the retry that makes it a duplicate.
enum ParcelHistoryAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/agro/parcels" }

    static func cropSeasonsPath(_ parcelID: String) -> String {
        "\(base)/\(parcelID)/crop-seasons"
    }

    static func weedObservationsPath(_ parcelID: String) -> String {
        "\(base)/\(parcelID)/weed-observations"
    }

    /// `201 { id }` — the created row's id and nothing else, so a screen that
    /// wants the row must re-read the archive. Not a defect to work around: a
    /// create that echoed the row would be a fourth shape of it.
    struct Created: Decodable, Equatable, Sendable {
        let id: String
    }

    // MARK: - Writes

    static func createCropSeason(
        parcelID: String, _ season: NewCropSeason
    ) async throws -> Created {
        let data = try await APIClient.shared.postReturningData(
            cropSeasonsPath(parcelID), body: season, idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: Created.self)
    }

    static func createWeedObservation(
        parcelID: String, _ observation: NewWeedObservation
    ) async throws -> Created {
        let data = try await APIClient.shared.postReturningData(
            weedObservationsPath(parcelID), body: observation, idempotencyKey: nil
        )
        return try await APIClient.shared.decode(data, as: Created.self)
    }

    // MARK: - Deletes

    /// `200 { ok: true }`, NOT 204 — so the response has a body and a
    /// caller that assumed no-content would be reading zero bytes.
    ///
    /// Soft delete server-side: the row is retained like every other
    /// agronomic record. Nothing here should tell a farmer it is erased.
    static func deleteCropSeason(parcelID: String, seasonID: String) async throws {
        try await deleteTreatingMissingAsDone(
            "\(cropSeasonsPath(parcelID))/\(seasonID)"
        )
    }

    static func deleteWeedObservation(parcelID: String, observationID: String) async throws {
        try await deleteTreatingMissingAsDone(
            "\(weedObservationsPath(parcelID))/\(observationID)"
        )
    }

    /// A 404 is SUCCESS for these two, and the reason is where the id came
    /// from.
    ///
    /// Both ids are read out of the archive this client just fetched, so a
    /// 404 means the row went away between the read and the delete — another
    /// device, or this device's own retry after a response that was lost on
    /// the way back. In every one of those the caller's goal already holds:
    /// the row is not in the archive. Surfacing «не е намерено» over a swipe
    /// that did exactly what was asked is the failure this prevents, and it
    /// is the same shape as `setTaskStatus`'s already-applied arm.
    ///
    /// ── Branching on the STATUS, not on a code ──
    ///
    /// The codes relayed for this pair were `CROP_SEASON_NOT_FOUND` and
    /// `WEED_OBSERVATION_NOT_FOUND`. Neither string appears anywhere in the
    /// generated spec — the 404 there is the generic "not found, or not
    /// visible to this tenant" every route carries. So matching them would
    /// be a guard that silently never fires, which is precisely the defect
    /// found in `FarmRiskModels` this month: a 409 arm written against an
    /// error the client could not throw, so the feature never worked.
    ///
    /// The status is in the spec. The status is what this reads.
    ///
    /// Pulled out as a PURE function so a test can prove the arm fires on the
    /// error this client actually throws. `FarmRiskModels.isAlreadyAsked`
    /// matched `.http(409)` for weeks while the client only ever threw
    /// `.conflict`, so the guard was unreachable and the feature silently
    /// never worked. A predicate over an `Error` is testable without a
    /// network; a `catch` pattern buried in a request is not.
    static func isAlreadyDeleted(_ error: Error) -> Bool {
        guard case APIClient.APIError.http(let status, _, _, _) = error else { return false }
        return status == 404
    }

    private static func deleteTreatingMissingAsDone(_ path: String) async throws {
        do {
            _ = try await APIClient.shared.deleteReturningData(path)
        } catch let error where isAlreadyDeleted(error) {
            return
        }
    }
}
