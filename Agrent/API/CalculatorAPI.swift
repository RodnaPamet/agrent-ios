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

    /// ── THIS ROUTE HONOURS IDEMPOTENCY, AND THIS CLIENT NOW USES IT. ──
    ///
    /// The chain rather than the conclusion, traced in agri-saas source by
    /// the server session at my request, after the generated spec turned out
    /// to be SILENT on grain while emphatic about six other writes:
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
    /// to be wrong before (#71, then again #73).
    ///
    /// Worth knowing how the wrong answer was produced, because it looked
    /// like evidence: a `grep -l "Idempotency-Key"` over the route files.
    /// That matches a file which merely MENTIONS the header — including one
    /// whose comment says it is ignored. A grep that cannot tell a use from a
    /// denial of use.
    ///
    /// ── So why is a key sent now? ──
    ///
    /// Because the caller can finally mint one that is safe to send. The
    /// hazard was never the header, it was reuse: send the SAME key after the
    /// operator corrects the amount and the server returns the ORIGINAL row,
    /// so the correction is silently dropped and the books keep the wrong
    /// figure. The owner decided on 2026-09-25 how to resolve that — a key
    /// per draft, RE-MINTED whenever the draft's content changes.
    ///
    /// `CostIdempotencyKey` is that key, and its header carries the full
    /// reasoning, including why the value is UUID-shaped. The rule for anyone
    /// calling this function: the key must be a function of the CONTENT being
    /// written. Never a fresh UUID per attempt (that defeats the dedupe
    /// entirely, which is what `ItemCatalogue.create` and
    /// `FarmRiskAPI.createLead` still do), and never a key held across a
    /// content change (that drops the change).
    ///
    /// Three consequences, all still deliberate:
    ///
    /// 1. **Nothing retries this automatically** — not the caller, not a
    ///    queue, not a pull-to-refresh. The key makes a retry SAFE; it does
    ///    not make one exist, and the owner chose the key without one.
    ///    `setTaskStatus`'s retry design must NOT be carried across: it is
    ///    safe there because the server compares state, and a create has no
    ///    prior state to compare with.
    /// 2. **A transport failure is reported as UNKNOWN, not as "not
    ///    saved".** After a timeout the app genuinely does not know whether
    ///    the row exists, and telling an operator it failed invites them to
    ///    enter it again by hand — which, typed afresh into a NEW sheet, is a
    ///    new nonce and therefore a new key, and writes a second row.
    /// 3. **The key does not license an outbox here.** A replay would be
    ///    deduped correctly, but nothing has been built to decide what a
    ///    queued cost means once the operator has moved on, and the queue
    ///    carries field operations only.
    static func create(
        _ entry: CreateCostEntry, idempotencyKey: String
    ) async throws -> Data {
        try await APIClient.shared.postReturningData(
            base, body: entry, idempotencyKey: idempotencyKey
        )
    }
}
