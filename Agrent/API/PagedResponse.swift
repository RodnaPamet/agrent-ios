import Foundation

/// A list endpoint's envelope, which is NOT the same shape on every endpoint
/// and is not even the same shape on the same endpoint.
///
/// ── The trap ──
///
///     GET /tasks            →  { rows: [Task], truncated: Bool }
///     GET /tasks?limit=50   →  { rows: [Task], nextCursor: String? }
///
/// Same route, two branches, chosen by whether the request carries
/// pagination. They now agree on the key — and that agreement is recent.
///
/// ── The trap that was here, and why the type survives it ──
///
/// The paginated branch used to key on `items`. Decode `rows` today, with no
/// `?limit`, and everything works; add pagination in six months — a change
/// about page size, nothing to do with decoding — and the array is absent,
/// and the screen shows "няма задачи" over a tenant holding hundreds. No
/// error, no decode failure, no log line. The bug was not written on the day
/// it was introduced; it was PLANTED, to detonate on a change that looked
/// unrelated.
///
/// It was removed at the source rather than documented here: the paginated
/// branch had exactly one caller, nothing consumed `{items, pageInfo}`, and
/// the client's own cursor accumulator reads `rows`/`nextCursor` — so the
/// endpoint was never paginable by the client that would have paginated it.
/// The journal route already reshaped for that reason; tasks simply never
/// did.
///
/// This type stays anyway, and `items` stays supported, because the defence
/// is cheap and the mistake is not specific to tasks — the next endpoint
/// will reach for whichever key its use case happened to return. What
/// remains is a real distinction worth decoding separately: `truncated`
/// means rows were DROPPED by a cap and the screen must say so; `nextCursor`
/// means there are more and here is how to ask.
///
/// ── And the rule you would derive is wrong ──
///
/// `/journal` splits the same way and keys its paginated branch `rows`:
///
///     journal, paginated  →  { rows:  [LogEntry], nextCursor }
///     tasks,   paginated  →  { items: [Task],     pageInfo }
///
/// So "the paginated branch is `rows`" is true, useful, and wrong on the
/// next endpoint — which makes it more dangerous than having no rule at all.
/// Each endpoint declares its own keys here rather than inheriting a habit.
///
/// The journal's key is also not the one its USE CASE returns. The use case
/// hands back `{items, pageInfo}` and the ROUTE reshapes it to
/// `{rows, nextCursor}` before responding — and the wire is what a client
/// sees. Guessing `items` from the use-case name produces a decode failure
/// and an ever-empty list, which is exactly how that was found the first
/// time. Read the route, never the use case.
///
/// ── Why an absent collection THROWS ──
///
/// Returning an empty page for a body with neither key would turn the
/// six-month bug above into a silent one permanently. Throwing puts the
/// failure on the developer who added `?limit`, at the moment they add it,
/// instead of on an operator standing in a field wondering where the work
/// went.
///
/// `LenientEnum` deliberately does not apply. It exists so ONE unknown enum
/// case degrades instead of killing an entire list — a real kindness, since
/// the server's vocabulary grows without us. A missing collection is not a
/// value we failed to recognise; it is the response not being the shape we
/// think it is, and it must not inherit that forgiveness.
struct PagedResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]

    /// Set on the UNPAGINATED branch when the server capped the response.
    ///
    /// Surfaced rather than swallowed. A list that is quietly incomplete, on
    /// a screen someone plans a day's work from, is the same defect as the
    /// empty one wearing a better disguise — and this one cannot be caught
    /// by looking, because a truncated list looks exactly like a short one.
    let truncated: Bool

    /// Present only on the paginated branch.
    let pageInfo: PageInfo?

    /// Present only on the journal-style paginated branch.
    let nextCursor: String?

    /// Whichever key the server used, for diagnostics — so a log line can
    /// say which branch was actually taken rather than leaving it to be
    /// inferred from whether anything worked.
    let collectionKey: String

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool?
        let endCursor: String?
        let totalCount: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case rows, items, truncated, pageInfo, nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // `decodeIfPresent` for BOTH, then decide — rather than `try? rows`
        // falling back to `try items`. The difference matters: a malformed
        // ELEMENT inside `rows` would make `try?` yield nil, and the fallback
        // would then report the far more alarming "no collection at all"
        // instead of the decoding error that actually happened.
        let rows = try c.decodeIfPresent([Item].self, forKey: .rows)
        let items = try c.decodeIfPresent([Item].self, forKey: .items)

        switch (rows, items) {
        case (let rows?, nil):
            self.items = rows
            self.collectionKey = "rows"
        case (nil, let items?):
            self.items = items
            self.collectionKey = "items"
        case (let rows?, _?):
            // Both present. Not expected from any endpoint we know, so this
            // is the server having changed in a way nobody told us about.
            // Take `rows` and say so, rather than picking one silently.
            self.items = rows
            self.collectionKey = "rows+items"
        case (nil, nil):
            throw DecodingError.keyNotFound(
                CodingKeys.items,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: """
                        Neither `rows` nor `items` is present. If a `limit` or \
                        cursor parameter was just added to this request, the \
                        server has switched branches and the collection is now \
                        under the other key — see PagedResponse.
                        """
                )
            )
        }

        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        self.pageInfo = try c.decodeIfPresent(PageInfo.self, forKey: .pageInfo)
        self.nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}
