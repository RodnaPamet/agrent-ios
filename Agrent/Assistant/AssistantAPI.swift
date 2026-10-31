import Foundation

/// `POST /api/t/{slug}/assistant/stream` (agri-saas #2578), and the flag
/// that offers it.
enum AssistantAPI {
    /// The runtime flag in `/api/auth/me`'s `featureFlags`. Absent means
    /// off, and the server can turn every flag off at once; the phone re-reads
    /// the flags on launch and on every return to the foreground, so the
    /// button can go between one use and the next.
    static let flag = "assistant.enabled"

    static var streamPath: String { "\(FarmPath.root)/assistant/stream" }

    /// One turn, as its events arrive. Refusals decided before the stream
    /// opens (204 off, 400, 403 budget, 429) are thrown as `APIError`s.
    static func ask(_ request: AssistantRequest) async throws -> AsyncThrowingStream<AssistantEvent, Error> {
        let payloads = try await APIClient.shared.eventStream(streamPath, body: request)
        return AsyncThrowingStream { continuation in
            let decoding = Task {
                do {
                    for try await payload in payloads {
                        // A payload that does not decode is skipped, as an
                        // unknown type is: one odd event never ends a turn.
                        if let event = try? JSONDecoder().decode(AssistantEvent.self, from: payload) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in decoding.cancel() }
        }
    }
}
