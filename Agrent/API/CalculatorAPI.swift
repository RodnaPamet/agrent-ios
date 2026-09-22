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

    /// ── THERE IS NO IDEMPOTENCY ON THIS ROUTE ──
    ///
    /// Measured server-side rather than inferred: idempotency here is
    /// per-usecase, not middleware, and exactly four usecases honour the
    /// header — journal, farm-task, field-operation, inventory. **Grain is
    /// not one of them**, and there is no natural-key pre-check either.
    ///
    /// So POST twice, with any key or none, and you get TWO ROWS. On a
    /// farm's books a lost response followed by a retry is a duplicated
    /// cost that silently changes net worth, and nothing on the server
    /// stops it.
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
    /// 3. **No `Idempotency-Key` is sent.** Sending one that is ignored
    ///    would read as protection that is not there.
    static func create(_ entry: CreateCostEntry) async throws -> Data {
        try await APIClient.shared.postReturningData(
            base, body: entry, idempotencyKey: nil
        )
    }
}
