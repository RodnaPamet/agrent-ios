import Foundation

/// A write whose route honours `Idempotency-Key`, tried again on a failure a
/// later attempt could fix — with the SAME key every time (#232).
///
/// agri-saas #1441 (live 2026-10-08) made a task's comment and its weed
/// observations replay-safe: a second request with the key of one that
/// already landed answers 201 with the ORIGINAL row. So a lost answer can be
/// retried without writing twice — which is what kept both writes from ever
/// being retried until then. The caller mints the key once per logical write
/// and closes over it; this only decides whether to go again.
///
/// ── What is worth another attempt ──
///
/// The outbox's own rule, `PendingOperations.isWorthRetrying`: no signal,
/// a 5xx, a 408 — the failures a later attempt could plausibly fix. Never a
/// 4xx: a refusal will be a refusal on the next try too.
///
/// ── Short, because someone is waiting on the screen ──
///
/// Two more tries, a second and then three apart. This is not the outbox's
/// drain, which can wait out an hour; it is a person holding a phone. So a
/// 429 is retried only when its `Retry-After` is within that wait — a rate
/// limit asking for longer is said, not sat through.
@MainActor
enum IdempotentRetry {
    static let delays: [Duration] = [.seconds(1), .seconds(3)]

    /// Runs `write`, and again after each delay while the failure is one
    /// worth retrying. Throws the last failure when it is not, or when the
    /// delays run out. `sleep` is a seam for the tests.
    static func run<T>(
        delays: [Duration] = IdempotentRetry.delays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ write: () async throws -> T
    ) async throws -> T {
        var remaining = delays[...]
        while true {
            do {
                return try await write()
            } catch {
                guard let next = remaining.popFirst(),
                      let wait = delay(after: error, planned: next),
                      !Task.isCancelled
                else { throw error }
                try await sleep(wait)
            }
        }
    }

    /// How long to wait before trying again after `error`, or nil to stop.
    static func delay(after error: Error, planned: Duration) -> Duration? {
        guard PendingOperations.isWorthRetrying(error) else { return nil }
        if case APIClient.APIError.http(429, _, _, _, let retryAfter) = error {
            guard let retryAfter, .seconds(retryAfter) <= planned else { return nil }
            return .seconds(retryAfter)
        }
        return planned
    }
}
