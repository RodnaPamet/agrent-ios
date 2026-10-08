import Foundation

enum WorkItemAPI {
    private static var base: String { "\(FarmPath.root)/tasks" }

    /// NO QUERY PARAMETERS, and that is a decision rather than a default.
    ///
    /// Two reasons, and the second is the one that binds:
    ///
    /// 1. The route branches on pagination. Without `limit` it answers
    ///    `{rows, truncated}`; with it, `{rows, nextCursor}`. `PagedResponse`
    ///    reads both, so this is not a decode question — but `truncated` is
    ///    only offered on the unpaginated branch, and until there is a paging
    ///    UI, being TOLD the list was capped is worth more than a page of it.
    ///
    /// 2. A query string is never safe on iOS. CFNetwork writes the full
    ///    request URL, query included, to the unified log from Apple's own
    ///    subsystems, and the app cannot suppress it — see ROADMAP, Phase 0.
    ///    Nothing here needs an id or a personal value in a parameter today,
    ///    and it should stay that way: filters belong in a header or a body.
    static var listPath: String { base }

    /// Decoded through the shared envelope, which throws rather than
    /// returning an empty list when neither `rows` nor `items` is present —
    /// see `PagedResponse`. The whole point is that the day someone adds
    /// `?limit` here, the failure lands on them and not on an operator
    /// looking at an empty screen in a field.
    /// The DETAIL route, which returns a whole task — 33 keys against the
    /// list's 11. An id in the PATH, never a query parameter: CFNetwork
    /// writes full request URLs to the unified log from Apple's own
    /// subsystems, and a path segment is as visible there as a query is, but
    /// this id is a task's own opaque identifier rather than anything about
    /// a person. The rule bites on `?assignee=` and filters, not here.
    static func detailPath(_ id: String) -> String { "\(base)/\(URLEscape.segment(id))" }

    static func decodeDetail(from data: Data) async throws -> WorkItem {
        try await APIClient.shared.decode(data, as: WorkItem.self)
    }

    /// Decodes `WorkItemSummary`, not `WorkItem`. The list route sends a
    /// PROJECTION — eleven keys of nineteen, with no `tenantId` and no
    /// `priority` — and a model built from the full field list fails the
    /// whole list on the first missing key. Measured, after it did.
    static func decodeList(from data: Data) async throws -> WorkItemPage {
        let page = try await APIClient.shared.decode(
            data, as: PagedResponse<WorkItemSummary>.self
        )
        return WorkItemPage(items: page.items, truncated: page.truncated)
    }
}

/// The list plus the one thing about it that is not in the list.
///
/// `truncated` is carried to the screen rather than dropped at the API
/// boundary. A capped list looks EXACTLY like a complete short one — unlike
/// an empty list, there is nothing on screen to notice — and this is a
/// screen someone plans a day's work from.
struct WorkItemPage: Equatable, Sendable {
    let items: [WorkItemSummary]
    let truncated: Bool
}

// MARK: - Writing

extension WorkItemAPI {

    /// `POST`, not `PATCH`, and its own path rather than a field on a
    /// general task update.
    static func statusPath(_ id: String) -> String { "\(detailPath(id))/status" }

    /// Change a task's status.
    ///
    /// ── A REPLAY IS NOT AN ERROR HERE ──
    ///
    /// This is the field action: made standing in a field, on a connection
    /// that drops, and replayed by the outbox. The route answers a replay
    /// with **200 and the current task**, not with a 400 and a code, so
    /// there is nothing for the client to recognise and no special arm to
    /// write. Send it again and it succeeds again.
    ///
    /// I built the code-recognition arm before asking, on the strength of a
    /// remark about the route's commonest 400. That remark was the history
    /// of the fix, not the contract. The arm is deleted rather than kept
    /// "just in case": dead code that defends against a case which cannot
    /// occur does not cost nothing — it tells the next reader the case is
    /// real.
    ///
    /// ── The Idempotency-Key is NOT what makes this safe ──
    ///
    /// Also measured: repeating the request with a BRAND NEW key returned
    /// 200 and the current task, exactly as repeating it with the same key
    /// did. Already-applied is decided by comparing STATE, not by the
    /// header. The key is still sent — it is the app's discipline on every
    /// write and the server dedupes elsewhere on it — but the property this
    /// route actually relies on is the state comparison, and believing
    /// otherwise would make the sharp edge below look harmless.
    ///
    /// ── THE SHARP EDGE, which is real and is easy to reintroduce ──
    ///
    /// Already-applied requires the resolution to be UNCHANGED or omitted.
    /// The same status with a DIFFERENT resolution is not a replay: it falls
    /// through to the transition check, where from == to is a no-op, and
    /// returns 400.
    ///
    /// So a retry must carry the IDENTICAL resolution. Any re-trimming,
    /// re-reading from a text field, or regenerating between attempts makes
    /// the second attempt a different request and breaks idempotency at
    /// exactly the moment it is needed. The caller mints the resolution ONCE
    /// alongside the key, and both are held across retries — the same rule
    /// as `JournalAPI.create`, for the same reason.
    ///
    /// ── No If-Match ──
    ///
    /// The route reads no headers and a task has no version. Concurrency is
    /// a real row lock taken inside the transaction, not an optimistic
    /// counter, so the journal's "an unguarded PATCH moves content without
    /// moving version" problem does not exist here. Pessimistic locking is
    /// why, and it is worth knowing rather than assuming symmetry.
    /// ── THE RESPONSE IS DISCARDED, and that is the finding ──
    ///
    /// Measured against production on 2026-09-22, moving TSK-8 from OPEN to
    /// IN_PROGRESS and then repeating the request:
    ///
    ///     real change  →  200, 25 keys — the bare updated row, no
    ///                     relations at all
    ///     replay       →  200, 32 keys — WITH assignee, createdBy,
    ///                     reviewer, comments, links, watchers, _count
    ///
    /// The same endpoint answers in two different shapes depending on
    /// whether the write did anything, because the change path returns
    /// `db.task.update(...)` with no `select` while the replay path returns
    /// the record it had already loaded WITH its relations. A client that
    /// modelled this response would decode one of them and fail the other,
    /// and it would fail on the replay — the path that only runs when the
    /// connection is bad, which is the worst possible place to put a decode
    /// error.
    ///
    /// So nothing here decodes it. The caller reloads the task afterwards
    /// and gets the detail shape, which is modelled and verified.
    ///
    /// ── Fixed server-side since; still discarded ──
    ///
    /// `setTaskStatus` now re-reads a replay BARE (`findBareById`), so both
    /// outcomes answer in the change path's shape (agri-saas, confirmed
    /// 2026-10-08). The reload stays: the screen needs the detail's
    /// relations, which only the detail route sends. Three shapes on one
    /// model now — the list's, the detail's, and this write's.
    @discardableResult
    static func setStatus(
        _ id: String,
        to status: WorkItemStatus,
        resolution: String?,
        idempotencyKey: String
    ) async throws -> Data {
        try await APIClient.shared.postReturningData(
            statusPath(id),
            body: SetStatus(status: status.rawValue, resolution: resolution),
            idempotencyKey: idempotencyKey
        )
    }

    /// `resolution` is encoded even when nil, because the schema
    /// distinguishes an omitted key from an explicit null and `.strip()`
    /// drops unknown keys rather than rejecting them — so sending the field
    /// is the readable choice and sending it as null is what "no
    /// resolution" means.
    private struct SetStatus: Encodable {
        let status: String
        let resolution: String?
    }
}

// MARK: - A task's parcels (agrent-ios#177)

extension WorkItemAPI {

    /// `GET /tasks/{taskId}/parcels` (agri-saas #1410): the task's parcels
    /// with their outlines, in ONE shape for every kind of task —
    /// deduplicated by parcel id, ordered by name then id, and `[]` for a
    /// task with none. A 404 is the task's, never "no parcels".
    ///
    /// Not where a field operation is drawn from. `GET /field-operations/{id}`
    /// carries each parcel's line status and the location around them, and
    /// the route's own documentation sends a field operation there.
    ///
    /// A task linked to a whole LOCATION has no parcels here: whether that
    /// link means «its parcels now» or «the ones it had when linked» is
    /// undecided server-side, so the route leaves it unexpanded.
    static func parcelsPath(_ id: String) -> String { "\(detailPath(id))/parcels" }

    static func decodeParcels(from data: Data) async throws -> [Parcel] {
        try await APIClient.shared.decode(data, as: TaskParcels.self).parcels
    }
}

/// The body of `GET /tasks/{taskId}/parcels`, each item as a `Parcel` — the
/// location route's type, whose every field past `id` and `name` is
/// optional — so these outlines are drawn by the code that draws every
/// other outline in the app.
struct TaskParcels: Decodable, Equatable, Sendable {
    let parcels: [Parcel]

    private enum CodingKeys: String, CodingKey { case parcels }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parcels = try container.decode([Lenient].self, forKey: .parcels).compactMap(\.parcel)
    }

    /// An outline this build cannot read is a parcel WITHOUT one — listed,
    /// and said to be off the map. Never dropped: the route's documentation
    /// asks for exactly that, «or your count will disagree with the task».
    /// Only an item with no id or name is dropped, which is not a parcel.
    private struct Lenient: Decodable {
        let parcel: Parcel?

        private struct Named: Decodable {
            let id: String
            let name: String
        }

        init(from decoder: Decoder) throws {
            if let whole = try? Parcel(from: decoder) {
                parcel = whole
            } else if let named = try? Named(from: decoder) {
                parcel = Parcel(id: named.id, name: named.name, cropType: nil, areaHa: nil,
                                geometry: nil, soilType: nil, cadastralId: nil, ekatte: nil,
                                hasActiveLease: nil, absentFromImportAt: nil)
            } else {
                parcel = nil
            }
        }
    }
}
