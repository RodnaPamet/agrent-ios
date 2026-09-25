import Foundation

enum CalculatorAPI {
    /// No query parameters. `getGrainNetWorth` takes `seasonId` optionally and
    /// both the API route and the web page pass none, so the native client
    /// passing one would diverge from the web for the same farm. It also keeps
    /// the request clear of the unified log: CFNetwork writes full request
    /// URLs, query included, and the app cannot suppress that.
    static var path: String { "/api/t/\(Config.tenantSlug)/grain/calculator" }

    static func decode(from data: Data) async throws -> CalculatorPayload {
        try await APIClient.shared.decode(data, as: CalculatorPayload.self)
    }
}

enum CostsAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/grain/costs" }

    /// `{ rows, totalCount, truncated }` — a FIFTH envelope variant in this
    /// API, measured. `PagedResponse` reads `rows` and would ignore
    /// `totalCount`, which is correct but lossy.
    static var listPath: String { base }

    static func decodeList(from data: Data) async throws -> CostPage {
        struct Envelope: Decodable {
            let rows: [CostEntry]
            let totalCount: Int?
            let truncated: Bool?
        }
        let e = try await APIClient.shared.decode(data, as: Envelope.self)
        return CostPage(
            items: e.rows, totalCount: e.totalCount, truncated: e.truncated ?? false
        )
    }

    /// ── THIS ROUTE DOES HONOUR IDEMPOTENCY. THIS CLIENT DOES NOT USE IT. ──
    ///
    /// Corrected 2026-09-25. `ROADMAP.md` was fixed in #71 and THIS COMMENT
    /// WAS MISSED — the document and the code beside the call disagreed for
    /// four days, and the comment is the one a person reads while changing
    /// this function. So here is the chain rather than the conclusion, traced
    /// in agri-saas source by the server session at my request, after the
    /// generated spec turned out to be SILENT on grain while emphatic about
    /// six other writes:
    ///
    ///     route reads `Idempotency-Key`
    ///       → passes it to `createCostEntry`
    ///       → usecase pre-checks `findByClientMutationId`
    ///       → plus a P2002 race backstop
    ///       → `clientMutationId` column, unique index
    ///
    /// `POST /grain/costs` and `POST /grain/yield-records` honour it today.
    /// `POST /grain/contracts` does NOT. Two yes, one no — not "grain" as a
    /// group, and generalising to the area is exactly how this comment came
    /// to be wrong.
    ///
    /// Worth knowing how the wrong answer was produced, because it looked
    /// like evidence: a `grep -l "Idempotency-Key"` over the route files.
    /// That matches a file which merely MENTIONS the header — including one
    /// whose comment says it is ignored. A grep that cannot tell a use from a
    /// denial of use.
    ///
    /// ── So why is `nil` still below? ──
    ///
    /// Because a key is only protection if a RETRY REUSES IT, and reusing one
    /// is not free here. Send the same key after the operator corrects the
    /// amount and the server returns the ORIGINAL row: the edit is silently
    /// dropped and the books keep the wrong figure. So the key has to be
    /// minted per logical write and re-minted whenever the draft changes,
    /// which is a decision about a money screen rather than a header.
    ///
    /// Put to the owner 2026-09-25. Until then this sends none and the
    /// caution below stands unchanged — it costs nothing, because the
    /// protection is worthless without the retry it would enable.
    ///
    /// Three consequences, all deliberate:
    ///
    /// 1. **Nothing retries this automatically** — not the caller, not a
    ///    queue, not a pull-to-refresh. `setTaskStatus`'s retry design must
    ///    NOT be carried across: it is safe there because the server
    ///    compares state, and a create has no prior state to compare with.
    /// 2. **A transport failure is reported as UNKNOWN, not as "not
    ///    saved".** After a timeout the app genuinely does not know whether
    ///    the row exists, and telling an operator it failed invites them to
    ///    enter it again — the one action that makes it worse.
    /// 3. **No `Idempotency-Key` is sent** — see above. Not because the
    ///    server would ignore it (it would not), but because nothing here
    ///    reuses a key, and a key used once protects against nothing.
    static func create(_ entry: CreateCostEntry) async throws -> Data {
        try await APIClient.shared.postReturningData(
            base, body: entry, idempotencyKey: nil
        )
    }
}
