import Foundation

/// An `Idempotency-Key` for ONE logical send (agrent-ios#196, from Борса's
/// #114).
///
/// A type rather than a `String` so the only way to get one is to mint it.
/// The server matches a replay on (sending PERSON, key) alone — not the
/// thread, not the text. So a key derived from the text would make the same
/// «Да» in two threads one message, and an empty key probably answers 409 on
/// the next empty-key send. Neither can be built from this.
struct MessageSendKey: Equatable, Sendable {
    let value: String

    /// Fresh, random. `mint` is injected only so a test can see which key
    /// came from which call; the app always takes the default.
    init(mint: () -> String = { UUID().uuidString }) {
        let minted = mint()
        value = minted.isEmpty ? UUID().uuidString : minted
    }
}

/// Which key a Send uses, across retries — what makes an UNKNOWN send
/// outcome safe to retry.
///
/// ── The rule ──
///
/// - The FIRST tap of Send for a (thread, exact trimmed text) mints a key.
/// - Every retry of that same text in that same thread REUSES it, so a send
///   whose response was lost replays the original instead of posting twice.
/// - Any change to the text — or another thread — is a NEW send and gets a
///   new key. Reusing the old one would be answered with the ORIGINAL message
///   as `replayed: true`, and the farmer would be told their correction went
///   out when it did not.
/// - ANY 201 clears it (`delivered`), a replay included. After a success there
///   is nothing to retry; sending the same words again is a second message.
///
/// A failure does NOT clear it. Every refusal the server can give before
/// storing — 429, validation, permission, block — happens before the row is
/// written, so reusing the key after one is safe; and after a timeout it is
/// the whole point. This is `FarmRiskStore.pendingKey`'s rule, with a message
/// in place of a lead.
struct MessageSendKeys: Equatable, Sendable {
    private struct Pending: Equatable, Sendable {
        let threadID: String
        let text: String
        let key: MessageSendKey
    }

    private var pending: Pending?

    /// The key for sending `text` (already trimmed — see `MessageBody`) to
    /// `threadID`: the pending one if this is a retry of it, else a new one.
    mutating func key(threadID: String, text: String,
                      mint: () -> String = { UUID().uuidString }) -> MessageSendKey {
        if let pending, pending.threadID == threadID, pending.text == text {
            return pending.key
        }
        let key = MessageSendKey(mint: mint)
        pending = Pending(threadID: threadID, text: text, key: key)
        return key
    }

    /// A 201 arrived — created or replayed. There is nothing left to retry.
    mutating func delivered() {
        pending = nil
    }

    /// Whether a retry of this exact send would reuse a key. For tests and for
    /// a screen that wants to say «опитайте отново» rather than «изпрати».
    func isPending(threadID: String, text: String) -> Bool {
        pending?.threadID == threadID && pending?.text == text
    }
}
