import Foundation

enum WorkItemAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/tasks" }

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
