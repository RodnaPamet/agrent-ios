import Foundation

/// «Довърши мероприятието»: an unfinished treatment recorded in full (owner,
/// 2026-10-25). Apart from the screen, so a test can read it, as
/// `TreatmentAbandon` is.
///
/// ── How the server finishes it ──
///
/// The record path, sent again under the treatment's own handle, finishes a
/// treatment that isn't complete instead of replaying it (agri-saas #2318).
/// The blocks already written are recognised by their derived keys and left
/// alone, and only the lines still PENDING are marked. The body is the
/// treatment as the server holds it (`TreatmentAPI.Body(resuming:)`), read
/// from `GET …/definition`. That read is write-gated as a correction is, so
/// «Довърши» is offered to whoever may correct the treatment
/// (`TreatmentCorrection.offered`).
///
/// ── Beside «Прекрати», not instead of it ──
///
/// The abandon stays the administrator's way to remove it all. Finishing
/// writes the parcels the treatment was entered for and nothing else.
enum TreatmentFinish {
    enum Outcome: Equatable, Sendable {
        case finished
        /// Not finished, in the server's words.
        case failed(String)
    }

    /// The two calls, a closure each, so a test sends nothing.
    struct Calls: Sendable {
        var definition: @Sendable (String) async throws -> TreatmentDefinition
        var send: @Sendable (TreatmentAPI.Body, String) async throws -> Void

        static let live = Calls(
            definition: { try await TreatmentCorrectionAPI.definition($0) },
            send: { body, handle in
                _ = try await APIClient.shared.postReturningData(
                    TreatmentAPI.recordPath, body: body, idempotencyKey: handle)
            })
    }

    static func run(_ handle: String, calls: Calls = .live) async -> Outcome {
        do {
            let definition = try await calls.definition(handle)
            guard let body = TreatmentAPI.Body(resuming: definition) else { return .failed(noDay) }
            try await calls.send(body, handle)
            return .finished
        } catch {
            return .failed(UserMessage.text(for: error))
        }
    }

    static let title = "Довърши мероприятието"
    static let finished = "Мероприятието е записано изцяло."
    /// A definition without a farm day: no line was ever marked, so there is
    /// nothing the server can finish from.
    static let noDay = "Мероприятието няма записан ден и не може да бъде довършено. Прекратете го и го запишете отново."
}
