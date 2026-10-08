/// Who said it, seen from the person holding the phone.
///
/// A pure mapping of the server's two flags, so the bubble's style, its
/// caption and its VoiceOver sentence all read one value, and a test can
/// hold every combination.
///
/// ── Three speakers, since agri-saas #1323 (#1298) ──
///
/// A conversation is private to PEOPLE, not shared by a farm: its audience
/// can include colleagues on either side. So a message is one of three:
///
///     mine                  -> me, the person holding this phone
///     fromMyFarm, not mine  -> a COLLEAGUE at my own farm
///     neither               -> the other side
///
/// The server computes both flags for the caller; nothing here compares ids.
enum MessageSpeaker: Equatable, Sendable, CaseIterable {
    /// The person holding the phone.
    case me
    /// Someone else at the same farm who is in this conversation's audience.
    case colleague
    /// The other side — whoever there is writing.
    case counterparty

    /// `mine` wins. The server computes `fromMyFarm` as "my farm and not me",
    /// so it never sends both; if it ever did, a message the server says I
    /// sent is mine, retract included.
    init(mine: Bool, fromMyFarm: Bool) {
        if mine {
            self = .me
        } else if fromMyFarm {
            self = .colleague
        } else {
            self = .counterparty
        }
    }

    /// What this speaker is to me: «Вие», a colleague, the other side. The
    /// caption when there is no name, and what VoiceOver adds to a
    /// colleague's (`MessageBubble.spoken`).
    ///
    /// «Вие» is the PERSON since #1323, never the farm.
    var label: String {
        switch self {
        case .me: "Вие"
        case .colleague: "Колега от стопанството"
        case .counterparty: "Отсрещната страна"
        }
    }

    /// The caption over a bubble: «Вие» for my own words whatever my name is,
    /// and for anyone else their name when the server has one (agri-saas
    /// #1399), else what they are to me. Two colleagues used to read alike;
    /// with names they do not.
    func caption(name: String?) -> String {
        switch self {
        case .me: label
        case .colleague, .counterparty: name ?? label
        }
    }

    /// My farm's side — me and a colleague — sits on the trailing edge, the
    /// other side on the leading one. A colleague DID write for my farm, so
    /// they are told apart from me by caption and bubble style, not by side.
    var isOurSide: Bool { self != .counterparty }
}
