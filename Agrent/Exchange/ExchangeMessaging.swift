import Foundation

// The RULES of exchange messaging (agrent-ios#114), kept apart from any
// screen or store so each can be tested without a network: `Tests/` has no
// URLProtocol seam and cannot observe an outgoing header, so a rule that
// lived inside a store would be a rule nothing checks.
//
// Five of them: the send key's lifecycle, what a sendable body is, how pages
// of a conversation merge, when to mark a conversation read, and what the
// unread badge counts.

// MARK: - The send key

/// An `Idempotency-Key` for ONE logical send.
///
/// A type rather than a `String` so the only way to get one is to mint it.
/// The server matches a replay on (sending farm, key) alone — not the thread,
/// not the text — so a key derived from the text would make the same «Да» in
/// two threads one message, and an empty key probably answers 409 on the
/// farm's next empty-key send. Neither can be built from this.
struct MessageSendKey: Equatable, Sendable {
    let value: String

    /// Fresh, random. `mint` is injected only so a test can see which key
    /// came from which call; the app always takes the default.
    init(mint: () -> String = { UUID().uuidString }) {
        let minted = mint()
        value = minted.isEmpty ? UUID().uuidString : minted
    }
}

/// Which key a Send uses, across retries.
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

// MARK: - What may be sent

/// The server's rule for a message body, applied before sending.
///
/// ── 4000, not the spec's 8000 ──
///
/// `SendExchangeMessage.body` is `maxLength: 8000` in the spec, and the Zod
/// schema agrees. The usecase then sanitises, trims, and refuses anything over
/// 4000 with `MESSAGE_TOO_LONG` — so 4001 to 8000 passes validation and fails
/// anyway. The composer holds the real limit.
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

// MARK: - Pages of one conversation

/// The messages of one conversation, as loaded so far: the newest page plus
/// every older page walked back to.
///
/// ── Why merge, and not replace ──
///
/// A poll asks for the NEWEST page every few seconds. The web replaces its
/// newest page on each poll and keeps older pages separately — and in a thread
/// longer than one page, once older pages have been loaded, every new message
/// pushes one message off the polled page that is in neither list. It
/// vanishes until reload. Here every page is merged BY ID into one list:
/// nothing is ever dropped by a poll.
///
/// ── Why sort, and not append ──
///
/// A message's `createdAt` is stamped before its transaction commits, and the
/// commit waits on the recipient's notification transaction. So a message can
/// become visible AFTER a newer one is already on screen. Appending new ids at
/// the end would show the conversation out of order; sorting by (`createdAt`,
/// `id`) — the server's own order — shows it as it happened.
///
/// ── The incoming copy wins ──
///
/// A message seen before can come back CHANGED: retracted since, so now a
/// tombstone. Keeping the old copy would leave a retracted message readable on
/// this phone until the screen was left.
struct Conversation: Equatable, Sendable {
    private(set) var messages: [ExchangeMessage]

    /// The `before` for the next older page. It tracks the OLDEST page walked
    /// to, so a poll never moves it.
    private(set) var olderCursor: String?

    /// Nothing older to load. Set by what ARRIVED, not by what was promised:
    /// a malformed `before` answers with the newest page and a 200, and a
    /// cursor is no guarantee of a non-empty page (`ParcelHistoryStore`).
    private(set) var exhausted: Bool

    /// From the first page of a fresh load.
    init(_ page: ExchangeThread) {
        messages = Self.ordered(page.messages)
        olderCursor = page.olderCursor
        exhausted = page.olderCursor == nil
    }

    var canLoadOlder: Bool { olderCursor != nil && !exhausted }

    /// The newest message on screen, if any — what `ReadMarking` compares
    /// the server's read pointer against.
    var newest: ExchangeMessage? { messages.last }

    /// What a merge changed, for the caller that decides what to do next.
    struct Arrival: Equatable, Sendable {
        /// Messages whose ids were not loaded before, in conversation order.
        var new: [ExchangeMessage]

        /// The newest page did not overlap what was loaded — more messages
        /// arrived than one page holds — so the loaded list was REPLACED by
        /// the newest page rather than left with a silent hole in the middle.
        /// Scrollback is lost and walkable again through `olderCursor`.
        var discontinuous: Bool = false

        /// New messages from the OTHER farm — the ones marking read is for.
        /// A tombstone counts: a message sent and retracted between two polls
        /// still moved `lastMessageAt`, so the inbox marks the thread unread
        /// until the pointer passes it.
        var fromOtherParty: Bool { new.contains { !$0.mine } }
    }

    /// Merge a NEWEST page — a poll, or the refetch after a send or a mark.
    @discardableResult
    mutating func mergeNewest(_ page: ExchangeThread) -> Arrival {
        let known = Set(messages.map(\.id))
        let incoming = page.messages
        let new = incoming.filter { !known.contains($0.id) }

        // ── The gap ──
        //
        // The newest page is a contiguous run ending at the newest message.
        // If it shares ANY id with what is loaded, the two runs join and the
        // union is contiguous. If it shares none AND has older messages
        // behind it, something between the two runs was never fetched —
        // typically after the app sat in the background with polling paused
        // while more than a page arrived. Merging would hide that hole behind
        // a list that looks complete, so the loaded list is replaced instead
        // and the older pages are walked again from this page's cursor.
        let overlaps = incoming.contains { known.contains($0.id) }
        if !messages.isEmpty, !incoming.isEmpty, !overlaps, page.olderCursor != nil {
            self = Conversation(page)
            return Arrival(new: Self.ordered(new), discontinuous: true)
        }

        merge(incoming)
        return Arrival(new: Self.ordered(new))
    }

    /// Merge an OLDER page, fetched with `before: olderCursor`.
    ///
    /// A page that carries NO NEW ID ends the walk for good: it is either the
    /// genuine end or the server restarting at the newest page over a cursor
    /// it could not read, and a client cannot tell those apart — nor does it
    /// need to. Appending the restart would repeat the conversation forever.
    mutating func mergeOlder(_ page: ExchangeThread) {
        let known = Set(messages.map(\.id))
        guard page.messages.contains(where: { !known.contains($0.id) }) else {
            exhausted = true
            return
        }
        merge(page.messages)
        olderCursor = page.olderCursor
        if page.olderCursor == nil { exhausted = true }
    }

    /// A retract THIS phone made, applied where the message sits.
    ///
    /// The refetch after a retract asks for the NEWEST page, so a message
    /// retracted from scrollback is not in it and would keep its body and
    /// its «Премахни» until the screen was left — the web's behaviour, and
    /// a message the farmer has just been told is gone, still on screen. The
    /// 200 is the server saying it is a tombstone now; this makes it one
    /// here, in the shape the server will send it from now on.
    mutating func tombstone(_ messageID: String) {
        messages = messages.map { message in
            guard message.id == messageID else { return message }
            return ExchangeMessage(
                id: message.id, senderTenantId: message.senderTenantId,
                mine: message.mine, body: nil, deleted: true,
                createdAt: message.createdAt
            )
        }
    }

    private mutating func merge(_ incoming: [ExchangeMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in incoming { byID[message.id] = message }
        messages = Self.ordered(Array(byID.values))
    }

    /// The server's order: oldest first, by `createdAt`, then by `id`.
    static func ordered(_ messages: [ExchangeMessage]) -> [ExchangeMessage] {
        messages.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
        }
    }
}

// MARK: - When to mark read

/// When a visible conversation posts `…/read`.
///
/// ── Twice as often as the web, on purpose ──
///
/// The web marks once per page mount. Here (owner decision, 2026-09-29) it
/// marks after the FIRST successful load, and AGAIN whenever a poll brings a
/// message from the other farm while the conversation is on screen — a farmer
/// looking at the message has read it, and «Ново» on the inbox row afterwards
/// would be wrong.
///
/// ── Not gated on `unreadCount` ──
///
/// The first mark fires even for a thread with nothing unread by that count.
/// `unreadCount` and the inbox's `hasUnread` disagree for an opened-but-empty
/// thread and after a retract, and it is `hasUnread` the badge shows.
///
/// ── Failures are swallowed by the caller ──
///
/// The UI test seam answers every write 501, and a failed mark is not a thing
/// a farmer can act on. It is not retried on a timer: the next arrival from
/// the other party marks again, which is when it matters.
struct ReadMarking: Equatable, Sendable {
    private(set) var markedOnce = false

    /// After a successful network load or poll has been merged: post `read`
    /// now? `visible` is the screen being on screen AND the app active — a
    /// conversation left open behind the lock screen has not been read.
    mutating func shouldMark(after arrival: Conversation.Arrival, visible: Bool) -> Bool {
        guard visible else { return false }
        if !markedOnce {
            markedOnce = true
            return true
        }
        return arrival.fromOtherParty
    }

    /// The first load, which has no `Arrival` of its own.
    mutating func shouldMarkAfterFirstLoad(visible: Bool) -> Bool {
        shouldMark(after: Conversation.Arrival(new: []), visible: visible)
    }

    /// ── The interim race rule ──
    ///
    /// `POST …/read` takes no body today and moves the pointer to the
    /// SERVER's now, so it can mark read a message this phone never showed —
    /// one that arrived between the last poll and the mark. Until the server
    /// accepts `{upTo: messageId}`, the rule is: if the pointer landed after
    /// the newest message shown, refetch the newest page once and merge it.
    ///
    /// In practice that is nearly every time — `readAt` is stamped at the
    /// mark, after every message the earlier read could have returned — and
    /// that is accepted: one extra read against a message never seen. When
    /// `upTo` appears in `openapi.json`, send the newest shown id instead and
    /// delete this.
    static func needsRefetch(readAt: Date, newestShown: Date?) -> Bool {
        guard let newestShown else { return true }
        return readAt > newestShown
    }
}

// MARK: - The unread badge

enum ExchangeInbox {
    /// The badge on Борса and the count in the inbox's segment label: how
    /// many THREADS have something unread — not how many messages, which the
    /// inbox rows do not carry.
    ///
    /// `hasUnread`, not `unreadCount`, for the reason `ReadMarking` gives.
    static func unreadCount(_ threads: [ExchangeThreadSummary]) -> Int {
        threads.reduce(0) { $0 + ($1.hasUnread ? 1 : 0) }
    }
}
