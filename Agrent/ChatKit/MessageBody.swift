import Foundation

/// The server's rule for a message body, applied before sending — the
/// composer's limits (agrent-ios#196, from Борса's #114).
///
/// ── 4000, not the spec's 8000 ──
///
/// The send body is `maxLength: 8000` in Борса's spec, and the Zod schema
/// agrees. The usecase then sanitises, trims, and refuses anything over 4000
/// with `MESSAGE_TOO_LONG` — so 4001 to 8000 passes validation and fails
/// anyway. The composer holds the real limit. A surface whose server sets
/// another one is where this grows a parameter, not before.
///
/// ── Counted in UTF-16 units ──
///
/// The server measures a JavaScript string's `length`, which is UTF-16 code
/// units. «👍🏽» is ONE `Character` in Swift, two code points, and FOUR units
/// there. Counting `Character`s would let an emoji-heavy message through the
/// composer and into a refusal.
///
/// ── Measured on the trimmed text, before the server's sanitiser ──
///
/// The sanitiser only ever removes (tags) or shortens (entities decode to one
/// character), so the raw trimmed length is an upper bound on what the server
/// measures — conservative in the safe direction. It can also turn a message
/// that is not empty here into one that is: `<ivan@abv.bg>` sanitises to
/// nothing and answers `MESSAGE_EMPTY`, which `UserMessage` says in Bulgarian.
enum MessageBody {
    static let maxLength = 4000

    /// Where a composer starts showing the count. Below this a counter is
    /// noise; the design shows one only near the limit.
    static let counterThreshold = 3600

    enum Verdict: Equatable, Sendable {
        /// Nothing but whitespace. Send stays disabled; nothing to say.
        case empty
        /// Over the limit by the server's measure. `length` is that measure.
        case tooLong(length: Int)
        /// Send this — the TRIMMED text, which is also what the send key is
        /// keyed on, so a trailing space typed after a failure is not a new
        /// message.
        case sendable(String)
    }

    static func validate(_ draft: String) -> Verdict {
        let trimmed = trimmed(draft)
        if trimmed.isEmpty { return .empty }
        let length = length(of: trimmed)
        if length > maxLength { return .tooLong(length: length) }
        return .sendable(trimmed)
    }

    /// The server's measure: UTF-16 units of the trimmed text.
    static func length(of text: String) -> Int {
        trimmed(text).utf16.count
    }

    /// Whether a counter belongs on screen for this draft.
    static func showsCounter(_ draft: String) -> Bool {
        length(of: draft) >= counterThreshold
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
