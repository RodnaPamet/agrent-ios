import Foundation

/// When a visible conversation marks itself read (agrent-ios#196, from
/// Борса's #114).
///
/// ── Twice as often as the web, on purpose ──
///
/// The web marks once per page mount. Here (owner decision, 2026-09-29) it
/// marks after the FIRST successful load, and AGAIN whenever a poll brings a
/// message from anyone but me — the other side or a colleague — while the
/// conversation is on screen. A farmer looking at the message has read it,
/// and «Ново» on the inbox row afterwards would be wrong.
///
/// The pointer is MINE: marking moves only the caller's, so opening a
/// conversation never clears a colleague's «Ново».
///
/// ── Not gated on an unread count ──
///
/// The first mark fires even for a thread with nothing unread by a count:
/// counts and an inbox's "has unread" can disagree for an opened-but-empty
/// thread and after a retract, and it is "has unread" a badge shows.
///
/// ── Failures are swallowed by the caller ──
///
/// The UI test seam answers every write 501, and a failed mark is not a thing
/// a farmer can act on. It is not retried on a timer: the next arrival from
/// someone else marks again, which is when it matters.
struct ReadMarking: Equatable, Sendable {
    private(set) var markedOnce = false

    /// After a successful network load or poll has been merged: mark read
    /// now? `visible` is the screen being on screen AND the app active — a
    /// conversation left open behind the lock screen has not been read.
    mutating func shouldMark<Message>(after arrival: ChatConversation<Message>.Arrival,
                                      visible: Bool) -> Bool {
        shouldMark(fromSomeoneElse: arrival.fromSomeoneElse, visible: visible)
    }

    /// The first load, which has no `Arrival` of its own.
    mutating func shouldMarkAfterFirstLoad(visible: Bool) -> Bool {
        shouldMark(fromSomeoneElse: false, visible: visible)
    }

    private mutating func shouldMark(fromSomeoneElse: Bool, visible: Bool) -> Bool {
        guard visible else { return false }
        if !markedOnce {
            markedOnce = true
            return true
        }
        return fromSomeoneElse
    }

    /// ── The interim race rule ──
    ///
    /// A mark that takes no body moves the pointer to the SERVER's now, so it
    /// can mark read a message this phone never showed — one that arrived
    /// between the last poll and the mark. Until the server accepts
    /// `{upTo: messageId}`, the rule is: if the pointer landed after the
    /// newest message shown, refetch the newest page once and merge it.
    ///
    /// In practice that is nearly every time — `readAt` is stamped at the
    /// mark, after every message the earlier read could have returned — and
    /// that is accepted: one extra read against a message never seen. When
    /// `upTo` appears in the spec, send the newest shown id instead and
    /// delete this.
    static func needsRefetch(readAt: Date, newestShown: Date?) -> Bool {
        guard let newestShown else { return true }
        return readAt > newestShown
    }
}
