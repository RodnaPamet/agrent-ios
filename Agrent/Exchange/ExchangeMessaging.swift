import Foundation

// The RULES of exchange messaging (agrent-ios#114) that are Борса's own,
// kept apart from any screen or store so each can be tested without a
// network: what the unread badge counts (and which inbox rows share a
// listing), and when a conversation is not available to the person (#1323).
//
// The rules of CHAT itself — the send key, what a sendable body is, how pages
// merge, when to mark read — were born here and moved to ChatKit
// (agrent-ios#196, P4.7), for the next chat surfaces to reuse.

/// Борса's conversation: ChatKit's, over Борса's messages. The name every
/// screen, store and test already used.
typealias Conversation = ChatConversation<ExchangeMessage>

// MARK: - The unread badge

enum ExchangeInbox {
    /// The badge on Борса and the count in the inbox's segment label: how
    /// many THREADS have something unread — not how many messages, which the
    /// inbox rows do not carry.
    ///
    /// `hasUnread`, not `unreadCount`, for the reason `ReadMarking` gives.
    ///
    /// MY count since #1323: `hasUnread` is per person, so a colleague
    /// reading a thread no longer lowers my badge, and two colleagues' badges
    /// can differ — they hold different inboxes.
    static func unreadCount(_ threads: [ExchangeThreadSummary]) -> Int {
        threads.reduce(0) { $0 + ($1.hasUnread ? 1 : 0) }
    }

    /// For each row, how many rows in this inbox are on the SAME LISTING —
    /// only where that is more than one.
    ///
    /// ── Why, and why only this ──
    ///
    /// A thread is per (listing, inquirer PERSON) since #1323, so a listing's
    /// owner may hold several rows on one listing — from different people,
    /// possibly at one buyer farm — and a buyer-side admin may see a
    /// colleague's thread beside their own. The rows carry the LISTING
    /// (commodity, region, tonnes, the owner's public name) and nothing about
    /// the other person: on the seller side that is deliberate, because the
    /// buyer's identity sits behind the inquiry contact-reveal gate. So two
    /// such rows are identical but for their time and «Ново».
    ///
    /// What the app CAN say truthfully is that a row is one of several on
    /// that listing — separate conversations, never to be merged — and that
    /// is all this computes. Numbering them («разговор 1», «разговор 2») is
    /// not possible honestly: the rows move with every message, and there is
    /// no stable order to number by. A per-thread label from the server is a
    /// follow-up (PARITY Gap 7).
    ///
    /// Within the loaded page only — the server's first hundred, which is
    /// all the inbox shows.
    static func siblings(_ threads: [ExchangeThreadSummary]) -> [String: Int] {
        let perListing = Dictionary(grouping: threads, by: \.listingId)
        var counts: [String: Int] = [:]
        for rows in perListing.values where rows.count > 1 {
            for row in rows { counts[row.id] = rows.count }
        }
        return counts
    }

    /// The line a row with siblings carries, and VoiceOver says.
    static func siblingNote(_ count: Int) -> String {
        "Един от \(count) разговора по тази обява"
    }
}

// MARK: - A conversation that is not there

/// Whether a failure means "this conversation is not available to you".
///
/// ── 404, and only 404 ──
///
/// Since #1323 a conversation is private to its people. Anyone outside its
/// audience — a colleague at a party farm included — gets 404
/// `THREAD_NOT_FOUND`, not 403: the row is invisible to them at the database
/// level, so the server cannot tell "not yours" from "does not exist", and
/// must not, or it would leak that a colleague is talking to someone.
///
/// The app meets it when a conversation is opened from a stale inbox, from a
/// link, or after the person's role at the farm changed under an open
/// screen. That is not an error a retry fixes, so it gets its own state
/// rather than the server-error one and its «Опитай отново».
///
/// The status alone decides, not the code: every 404 the thread routes can
/// give means the same thing to the person, and a renamed code must not
/// turn this back into a generic failure.
enum ConversationAvailability {
    static func isUnavailable(_ error: Error) -> Bool {
        if case APIClient.APIError.http(let status, _, _, _, _) = error {
            return status == 404
        }
        return false
    }

    static let title = "Разговорът не е достъпен"

    /// Both possibilities, because the server cannot say which — and neither
    /// names a colleague or claims the conversation was deleted.
    static let message = "Този разговор не е достъпен за Вас. Възможно е да е между други хора "
        + "от стопанството или вече да не съществува."
}
