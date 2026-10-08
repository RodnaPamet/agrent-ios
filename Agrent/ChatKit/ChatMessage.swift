import Foundation

/// What ChatKit needs from a message (agrent-ios#196, P4.7): who said it,
/// when, and what — or that it was retracted.
///
/// ChatKit is the conversation engine Борса's messaging was built on, lifted
/// out so the next chat surfaces — direct messages (P8), channels (P9) —
/// reuse it rather than copy it. Борса's message is the first to conform; a
/// later one conforms the same way, and the rules, the engine and the bubble
/// above it work unchanged. `ChatKitBoundaryTests` keeps Борса's own names
/// out of this folder.
protocol ChatMessage: Identifiable, Equatable, Sendable where ID == String {
    var createdAt: Date { get }

    /// Written by the person holding the phone — the PERSON, never their farm.
    var mine: Bool { get }

    /// Who said it, seen from the person holding the phone.
    var speaker: MessageSpeaker { get }

    /// The sender's name as the server sent it. Raw: `displayName` is what
    /// may be shown.
    var senderName: String? { get }

    /// Plain text after the server's sanitiser — render it verbatim, never as
    /// markdown or a `LocalizedStringKey`. Null exactly when retracted.
    var body: String? { get }

    /// Retracted. A tombstone KEEPS ITS PLACE: dropping it would open a hole
    /// in the other party's scrollback where something they read used to be.
    var isTombstone: Bool { get }

    /// This message as the tombstone the server sends for it after a
    /// retract — so a retract this phone made shows at once, where the
    /// message sits (`ChatConversation.tombstone`).
    func tombstoned() -> Self
}

extension ChatMessage {
    /// The name to show, or nil for none — and then the caption says what
    /// the sender is to me instead (`MessageSpeaker.caption`). None, for
    /// three kinds of name:
    ///
    /// - nothing but spaces: a blank caption is no caption;
    /// - a ciphertext: names are encrypted at rest, and a decryption that
    ///   fails has reached a screen before (`WorkItemSummary.Assignee`,
    ///   2026-09-22) — VoiceOver would spell it out before every message;
    /// - one of the APP'S OWN speaker words. A name is the sender's to
    ///   choose, and the other side named «Вие» or «Колега от
    ///   стопанството» would otherwise caption their words as mine or a
    ///   colleague's.
    var displayName: String? {
        guard let trimmed = senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !WorkItemSummary.Assignee.isCipherEnvelope(trimmed),
              !MessageSpeaker.allCases.contains(where: {
                  $0.label.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
              })
        else { return nil }
        return trimmed
    }

    /// «Премахни» is offered only on MY OWN still-present messages: the
    /// server checks the sending PERSON and refuses anyone else, a colleague
    /// included.
    var mayRetract: Bool { mine && !isTombstone }
}
