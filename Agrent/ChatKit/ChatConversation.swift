/// The messages of one conversation, as loaded so far: the newest page plus
/// every older page walked back to (agrent-ios#196, from Борса's #114).
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
struct ChatConversation<Message: ChatMessage>: Equatable, Sendable {
    private(set) var messages: [Message]

    /// The `before` for the next older page. It tracks the OLDEST page walked
    /// to, so a poll never moves it.
    private(set) var olderCursor: String?

    /// Nothing older to load. Set by what ARRIVED, not by what was promised:
    /// a malformed `before` answers with the newest page and a 200, and a
    /// cursor is no guarantee of a non-empty page (`ParcelHistoryStore`).
    private(set) var exhausted: Bool

    /// From the first page of a fresh load.
    init<Page: ChatPage>(_ page: Page) where Page.Message == Message {
        messages = Self.ordered(page.messages)
        olderCursor = page.olderCursor
        exhausted = page.olderCursor == nil
    }

    var canLoadOlder: Bool { olderCursor != nil && !exhausted }

    /// The newest message on screen, if any — what `ReadMarking` compares
    /// the server's read pointer against.
    var newest: Message? { messages.last }

    /// What a merge changed, for the caller that decides what to do next.
    struct Arrival: Equatable, Sendable {
        /// Messages whose ids were not loaded before, in conversation order.
        var new: [Message]

        /// The newest page did not overlap what was loaded — more messages
        /// arrived than one page holds — so the loaded list was REPLACED by
        /// the newest page rather than left with a silent hole in the middle.
        /// Scrollback is lost and walkable again through `olderCursor`.
        var discontinuous: Bool = false

        /// New messages from ANYONE BUT ME — the ones marking read is for.
        ///
        /// That includes a colleague. The read pointer is the person's, and
        /// an inbox computes "unread" as `lastMessageAt > my pointer` whoever
        /// wrote, so a colleague's reply arriving on screen leaves «Ново»
        /// behind unless it is marked like the other side's.
        ///
        /// A tombstone counts: a message sent and retracted between two polls
        /// still moved `lastMessageAt`, so the inbox marks the thread unread
        /// until the pointer passes it.
        var fromSomeoneElse: Bool { new.contains { !$0.mine } }
    }

    /// Merge a NEWEST page — a poll, or the refetch after a send or a mark.
    @discardableResult
    mutating func mergeNewest<Page: ChatPage>(_ page: Page) -> Arrival where Page.Message == Message {
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
            self = ChatConversation(page)
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
    mutating func mergeOlder<Page: ChatPage>(_ page: Page) where Page.Message == Message {
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
        messages = messages.map { $0.id == messageID ? $0.tombstoned() : $0 }
    }

    private mutating func merge(_ incoming: [Message]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in incoming { byID[message.id] = message }
        messages = Self.ordered(Array(byID.values))
    }

    /// The server's order: oldest first, by `createdAt`, then by `id`.
    static func ordered(_ messages: [Message]) -> [Message] {
        messages.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
        }
    }
}
