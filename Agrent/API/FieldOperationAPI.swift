import Foundation

/// A field operation's prescription lines, and marking one (agrent-ios#138).
///
/// ── The write, read from the route rather than from the issue ──
///
/// `PATCH /field-operations/{taskId}/parcels/{lineId}` with `{status}`:
///
///   - WHO: `canWrite`, or the job's assigned operator without it — the
///     route refuses anyone else with 403 `OPERATION_NOT_ASSIGNED_TO_YOU`.
///   - THE LOCK: `If-Match: <version>`, parsed by the server's one strict
///     parser (`src/lib/http/if-match.ts`). An ABSENT header skips the check
///     — a silent last-write-wins — so this client never sends a mark
///     without one: `mark` takes the version as a non-optional `Int`.
///   - A STALE VERSION has two answers. If the line already carries the
///     status this write wanted, 200 with `alreadyApplied: true` and the
///     current version — a replay of the operator's own success, which is
///     not a conflict. Otherwise 409 `STALE_DATA`, with `currentVersion`,
///     `currentStatus` and `expectedVersion` under `error.details`.
///   - NO `Idempotency-Key`. The route reads none, and sending one would
///     read as protection that is not there (`APIClient.postReturningData`).
///     Replay safety on this route IS the lock: a lost response replays with
///     the version seen before the write and comes back `alreadyApplied`.
///   - SIDE EFFECTS, real ones: completing a line deducts stock and files a
///     ДНЕВНИК entry; the last line moves the job to PENDING_REVIEW and
///     queues the farm-record PDF. Never sent from development, CI or the
///     screenshot harness — the seam answers it 501.
enum FieldOperationAPI {
    private static var base: String { "\(FarmPath.root)/field-operations" }

    /// The whole job — the task, its lines, the location and its parcels.
    /// The id is the TASK's: a field operation is a task of type
    /// `FIELD_OPERATION`, and a 404 also covers "not that type".
    static func detailPath(_ taskID: String) -> String {
        "\(base)/\(URLEscape.segment(taskID))"
    }

    /// One prescription LINE of the job. `lineID` is the `OperationParcel`
    /// id, not a parcel id — the spec says so in as many words. Given the
    /// farm for the outbox's replay, as `LocationsAPI.operationsPath` is.
    static func linePath(taskID: String, lineID: String, tenant: String? = FarmPath.openSlug) -> String {
        "\(FarmPath.root(for: tenant))/field-operations/\(URLEscape.segment(taskID))/parcels/\(URLEscape.segment(lineID))"
    }

    static func decodeDetail(from data: Data) async throws -> FieldOperationDetail {
        try await APIClient.shared.decode(data, as: FieldOperationDetail.self)
    }

    /// The request body, as BYTES — built once, sent live, and stored as-is
    /// if the mark has to wait on the phone. `note` is not sent: the screen
    /// has nowhere to write one, and an explicit null would CLEAR a target
    /// note somebody else wrote (`...(note !== undefined ? { targetNote }`).
    static func body(_ status: OperationLineStatus) async throws -> Data {
        try await APIClient.shared.encodeBody(Mark(status: status.rawValue))
    }

    private struct Mark: Encodable {
        let status: String
    }

    /// Everything one mark needs, decided before the request leaves.
    struct MarkRequest: Equatable, Sendable {
        let taskID: String
        let lineID: String
        let body: Data
        /// The line's version as the screen READ it — the `If-Match`.
        let seenVersion: Int
        /// The farm the mark was made on, taken when the request is BUILT.
        /// A mark that fails to send is queued afterwards, from a task that
        /// can outlive the screen — after a farm switch, or Изход — and the
        /// queued copy has to go where the tap was, not where the app is.
        var farm: String? = FarmPath.openSlug

        var path: String { FieldOperationAPI.linePath(taskID: taskID, lineID: lineID, tenant: farm) }
    }

    /// What a landed mark reports back, read leniently: the 200 carries
    /// `version` (the line's new one, or the server's current one on an
    /// `alreadyApplied` replay) and `resolved` (this mark finished the job).
    /// Neither is worth failing a write that LANDED over — the screen
    /// reloads after it anyway.
    struct Landed: Equatable, Sendable {
        let version: Int?
        let resolved: Bool
    }

    /// Send one mark, guarded by the version the operator saw.
    static func mark(_ request: MarkRequest) async throws -> Landed {
        let data = try await APIClient.shared.patchRaw(
            request.path, body: request.body, ifMatch: request.seenVersion)
        return landed(from: data)
    }

    /// A plain `JSONDecoder` on purpose: the two fields are a number and a
    /// boolean, so the client decoder's date handling has nothing to do, and
    /// a pure function is one a test can call without the actor.
    static func landed(from data: Data) -> Landed {
        struct Wire: Decodable {
            let version: Int?
            let resolved: Bool?
        }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        return Landed(version: wire?.version, resolved: wire?.resolved ?? false)
    }
}
