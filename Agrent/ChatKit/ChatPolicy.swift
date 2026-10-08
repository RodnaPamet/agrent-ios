import Foundation

/// The conversation's rules that are about chat itself, not about one
/// product's threads (agrent-ios#196): the poll's cadence and backoff, when
/// Send is live, what stays in the composer, its counter, and what a failed
/// send says — the unknown outcome included. Борса's own rules (who may
/// write, blocks, its badge) stay in its `MessagingPolicy`.
enum ChatPolicy {
    /// The web's own cadence for an open conversation. Polls run ONLY while
    /// the screen is on screen and the app is active — the loop is a `.task`
    /// keyed on the scene phase, so leaving the screen or locking the phone
    /// cancels it.
    static let conversationInterval: Duration = .seconds(5)

    /// How long a poller waits before its next request.
    ///
    /// The interval, unless the last request was a 429 — then the server's
    /// `Retry-After` (through `RateLimitGate.wait`, so its floor and its
    /// fallback are the app's one rule), and never LESS than the interval: a
    /// one-second `Retry-After` is not an invitation to poll thirty times
    /// faster than it would have.
    ///
    /// A poll's 429 is NOT absorbed into `RateLimitPause.messages`. Reads are
    /// limited by the edge's read tier, per (tenant, address, user); sends
    /// draw on the farm's message budget. A throttled poll says nothing
    /// about whether a message may be sent.
    static func nextPoll(after error: Error?, interval: Duration) -> Duration {
        guard let error, let wait = RateLimitGate.wait(for: error) else { return interval }
        return max(wait, interval)
    }

    /// Whether Send is live.
    ///
    /// A failed send stays sendable — that is the whole point of keeping its
    /// key — and what disables Send is only: nothing to send (blank, or over
    /// the server's limit), a send already in flight, the farm's message
    /// budget paused by a 429, or the server having already said it refuses
    /// this sender here (`refused` — a block, on Борса).
    static func canSend(draft: String, sending: Bool, paused: Bool, refused: Bool) -> Bool {
        guard !sending, !paused, !refused else { return false }
        if case .sendable = MessageBody.validate(draft) { return true }
        return false
    }

    /// What stays in the field after a 201.
    ///
    /// Empty, if what is there is still what was sent. If the farmer kept
    /// typing while the send was in flight, what is there now is a NEW
    /// message and it stays — the web clears it along with the sent one.
    static func draftAfterDelivery(_ draft: String, sent: String) -> String {
        if case .sendable(let now) = MessageBody.validate(draft), now == sent { return "" }
        if case .empty = MessageBody.validate(draft) { return "" }
        return draft
    }

    /// The counter under the composer, near the limit only.
    static func counter(for draft: String) -> (text: String, spoken: String, over: Bool)? {
        guard MessageBody.showsCounter(draft) else { return nil }
        let length = MessageBody.length(of: draft)
        let limit = MessageBody.maxLength
        return ("\(length) / \(limit)", "\(length) от \(limit) знака", length > limit)
    }

    /// Whether a failed send may in fact have been delivered.
    ///
    /// A timeout or a dropped connection after the request left says nothing
    /// about whether the server stored it, and neither does a gateway's 5xx.
    /// Every other failure is an answer from before the row was written.
    static func outcomeUnknown(_ error: Error) -> Bool {
        if let url = error as? URLError {
            return url.code == .timedOut || url.code == .networkConnectionLost
        }
        if case APIClient.APIError.http(let status, _, _, _, _) = error {
            return status >= 500
        }
        return false
    }

    /// The line under the composer after a send failed.
    ///
    /// When the outcome is unknown it says so, and says that pressing Send
    /// again is safe — which it is, because the retry carries the same
    /// `Idempotency-Key` (`MessageSendKeys`) and a stored message comes back
    /// `replayed`. «Не е изпратено» there would be a claim the app cannot
    /// support.
    static func sendFailure(for error: Error) -> String {
        if outcomeUnknown(error) {
            return "Не е ясно дали съобщението е изпратено. Изпратете го отново — "
                + "няма да бъде получено два пъти."
        }
        return "Съобщението не е изпратено. \(UserMessage.text(for: error))"
    }

    /// What failed, then why — «Разговорът не може да бъде затворен. Няма
    /// интернет връзка.» The web shows only the first half.
    static func failure(_ what: String, _ error: Error) -> String {
        "\(what) \(UserMessage.text(for: error))"
    }
}
