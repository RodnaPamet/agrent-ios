import Foundation

/// Exchange MESSAGING: the conversation a buyer and a listing's owner hold
/// about one listing (agrent-ios#114).
///
/// ── Modelled from the contract, not from the wire ──
///
/// Unlike the listings (captured off production, see `ExchangeModels`), these
/// payloads are cross-tenant PRIVATE MESSAGES, and none was recorded: the repo
/// is public and a real conversation is not publishable. The shapes are taken
/// from agri-saas `src/generated/openapi.json` (schemas `ExchangeThread`,
/// `ExchangeThreadSummary`, `ExchangeMessage`, `SendExchangeMessage` and the
/// nine operations' responses) and cross-checked against the usecase that
/// produces them, `src/app-layer/usecases/exchange-messaging.ts`. The fixtures
/// under `Tests/Fixtures/exchange-thread*.json` are SYNTHETIC.
///
/// ── Four rules the types below follow ──
///
/// 1. A key the spec lists as `required` but types `["string","null"]` —
///    `sellerDisplayName`, `olderCursor`, `body`, `nextCursor` — is a Swift
///    OPTIONAL. Present-and-null is a real value on the wire, and a
///    non-optional there fails the whole inbox over one row.
///
/// 2. `listingCommodity` decodes into a property named `commodity`. The CI
///    guard that routes commodity slugs through `CommodityName` greps for
///    `.commodity`, case-sensitively; `.listingCommodity` would slip past it
///    and put a raw English slug on a Bulgarian screen.
///
/// 3. Timestamps are `Date`. The spec types them as bare `string` with no
///    `format`, which is what made parcel history keep strings — but there a
///    date-only value is what the published contract still PERMITS. Here the
///    server serialises a JS `Date` every time (`toISOString()`: UTC, three
///    fractional digits, `Z`), which `APIClient`'s decoder accepts, and the
///    conversation's ordering needs a real instant to sort on.
///
/// 4. A WRITE's response is informative, never the proof of success — the 2xx
///    is. So a response type requires only the field a caller cannot do
///    without, and defaults the flags. A delivered message must never read as
///    a failure because a boolean went missing: the farmer would press Send
///    again, and although the key would replay it, they would have been told
///    something false.
///
/// ── Role is the LISTING's, not the trade's ──
///
/// `seller` means the listing's OWNER, including on a BUY listing where the
/// owner is the one buying. The payloads carry no listing side, so wording
/// that depends on it is only possible where the side is known
/// (`ListingDetailView`); everywhere else the labels are side-neutral.
enum ExchangeThreadRole: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: ExchangeThreadRole { .unknown }
    case seller
    case inquirer
    case unknown

    /// The inbox's role marker. Side-neutral — not «Вие продавате»: on a BUY
    /// listing the owner is buying, and the row cannot tell which.
    ///
    /// And FARM-level, «Наша», not «Вашата» / «Вие питате» as before #1323.
    /// The role is which side my FARM is on, while «Вие» now means the person:
    /// an admin answering on a colleague's listing does not own it, and a
    /// buyer-side admin reading a colleague's thread is not the one asking.
    /// «Ние» is the farm in Bulgarian farm talk, and true for every reader.
    var label: String {
        switch self {
        case .seller: "Наша обява"
        case .inquirer: "Наше запитване"
        case .unknown: "—"
        }
    }

    /// Block and unblock are the listing owner's alone (`BLOCK_SELLER_ONLY`) —
    /// the owning FARM's: anyone in the seller-side audience, the creator or
    /// an admin.
    /// An unrecognised role is NOT the owner: offering a control the server
    /// then refuses is worse than not offering it.
    var ownsListing: Bool { self == .seller }
}

/// `GET /api/t/{slug}/exchange/threads` — an envelope keyed `threads`.
///
/// Neither `PagedResponse` (rows/items) nor `ExchangeListingPage` (rows)
/// fits: the key is per route here, as it is everywhere in this API.
struct ExchangeThreadPage: Decodable, Equatable, Sendable {
    let threads: [ExchangeThreadSummary]

    /// Null exactly when there is no further page — the server over-fetches
    /// one row to decide, so a full last page does not point at an empty one.
    let nextCursor: String?
}

/// One inbox row — of the CALLER's own inbox since #1323, not the farm's
/// shared one: threads they opened, threads on listings they created, and
/// threads on either where they are an OWNER/ADMIN of a party farm. Two
/// colleagues see different lists.
///
/// ── Several rows on one listing are several PEOPLE ──
///
/// A thread is per (listing, inquirer PERSON), so a listing owner can hold
/// several rows on one listing from one buyer farm, and a buyer-side admin
/// can see a colleague's thread beside their own. They are different
/// conversations and are never merged. Nothing in the row says who the
/// other person is — deliberately, on the seller's side, because the buyer's
/// identity sits behind the inquiry contact-reveal gate — so the inbox can
/// only say that a row is one of several (`ExchangeInbox.siblings`).
struct ExchangeThreadSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let listingId: String

    /// A canonical slug. Render it through `CommodityName`. See the header.
    let commodity: String

    /// The listing's region, in ENGLISH (`ExchangeListing.regionName` is the
    /// English oblast name) and with no code beside it. Optional although the
    /// spec requires it: the row still has a commodity and a time to show,
    /// and a missing region must not cost the inbox.
    let listingRegionName: String?

    /// An exact decimal STRING (Prisma `Decimal(14,3).toString()`: `"25"`,
    /// `"25.5"`), never a number. Format with `Exchange.tonnes`. Optional for
    /// the reason `listingRegionName` is.
    let listingQuantityTonnes: String?

    /// The LISTING OWNER's opt-in public name, on every row — including rows
    /// where this farm is the owner. Never the inquirer's identity. Null when
    /// the owner set none.
    let sellerDisplayName: String?

    let role: ExchangeThreadRole

    /// The thread's creation time until its first message.
    let lastMessageAt: Date

    let closed: Bool

    /// THE unread signal. Not the thread's `unreadCount`: an opened-but-empty
    /// thread and one whose last message was retracted have `unreadCount` 0
    /// and `hasUnread` true, and gating on the count would leave «Ново» on
    /// the row for good.
    ///
    /// PER PERSON since #1323: a colleague reading the thread no longer
    /// clears it for me, and a colleague's reply now sets it for me.
    let hasUnread: Bool

    var quantity: Decimal? { WireDecimal.parse(listingQuantityTonnes) }

    private enum CodingKeys: String, CodingKey {
        case id, listingId
        case commodity = "listingCommodity"
        case listingRegionName, listingQuantityTonnes, sellerDisplayName
        case role, lastMessageAt, closed, hasUnread
    }
}

/// `GET /api/t/{slug}/exchange/threads/{threadId}` — one PAGE of a
/// conversation plus its header.
///
/// The messages are the END of the conversation, oldest first. `olderCursor`
/// passed as `before` gives the page before it. The header fields are
/// recomputed on every page, older pages included.
struct ExchangeThread: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let listingId: String

    /// A canonical slug. Render it through `CommodityName`.
    let commodity: String

    let role: ExchangeThreadRole
    let lastMessageAt: Date

    /// Closed refuses nothing: the next message from either party reopens it.
    let closed: Bool

    /// The block, reported to BOTH parties. PERSON-level since agri-saas
    /// #1397: the listing farm refuses this conversation's other person, on
    /// every listing of its own and not only in this thread — and not that
    /// person's colleagues.
    ///
    /// The server does not report it reliably yet: every caller of its
    /// `isBlocked` passes a tenant id where the block now holds a user id, so
    /// this reads false for every thread (agri-saas #1403).
    let blocked: Bool

    /// The caller's exact unread count — the CALLER's, per person since
    /// #1323. Decoded but NOT the unread signal — see
    /// `ExchangeThreadSummary.hasUnread` — and optional because nothing here
    /// depends on it.
    let unreadCount: Int?

    /// Null once the start of the conversation is on this page.
    let olderCursor: String?

    let messages: [ExchangeMessage]

    private enum CodingKeys: String, CodingKey {
        case id, listingId
        case commodity = "listingCommodity"
        case role, lastMessageAt, closed, blocked, unreadCount, olderCursor, messages
    }
}

/// One message, or the tombstone of one.
///
/// A retracted message KEEPS ITS PLACE: `deleted: true`, `body: null`. It is
/// rendered as «Съобщението е премахнато», never dropped — dropping it would
/// open a hole in the other party's scrollback where something they read
/// used to be.
///
/// ── Three speakers, since agri-saas #1323 (#1298) ──
///
/// A conversation is private to PEOPLE now, not shared by the farm: its
/// audience is the person who opened it, the listing's creator, and the
/// OWNER/ADMIN members of either farm. So a message is one of three, and
/// `speaker` says which:
///
///     mine                  -> me, the person holding this phone
///     fromMyFarm, not mine  -> a COLLEAGUE at my own farm — e.g. the seller
///                              admin answering for the listing's creator
///     neither               -> the other side
///
/// The server computes both flags for the caller; nothing here compares ids.
struct ExchangeMessage: Decodable, Equatable, Sendable, Identifiable {
    let id: String

    /// A TENANT id, never a user. Optional because nothing reads it: who said
    /// it is `speaker`, which the server computes for the caller. Comparing
    /// tenant ids here would be re-deriving that, worse.
    let senderTenantId: String?

    /// The sending PERSON's opaque id (#1323). Required by the spec, optional
    /// here because nothing on screen depends on it: it is an id, not a name,
    /// and the payload carries no name — a server follow-up, PARITY Gap 7.
    let senderUserId: String?

    /// SENT BY ME, the person (#1323). It used to mean "sent by my farm", so a
    /// colleague's message was `mine` too; it no longer is.
    let mine: Bool

    /// Sent by someone ELSE at my own farm (#1323). Required by the spec, but
    /// DEFAULTED to false when absent: absent means a server from before
    /// #1323, and there a colleague's message already arrived as `mine`, so
    /// false is exactly what that server meant. Requiring it would cost the
    /// whole conversation on that server over a flag it could never send.
    let fromMyFarm: Bool

    /// Plain text after the server's sanitiser. Render it VERBATIM
    /// (`Text(verbatim:)`): never markdown, never HTML, never a
    /// `LocalizedStringKey`. Null exactly when `deleted`.
    let body: String?

    let deleted: Bool
    let createdAt: Date

    init(id: String, senderTenantId: String?, senderUserId: String? = nil,
         mine: Bool, fromMyFarm: Bool = false,
         body: String?, deleted: Bool, createdAt: Date) {
        self.id = id
        self.senderTenantId = senderTenantId
        self.senderUserId = senderUserId
        self.mine = mine
        self.fromMyFarm = fromMyFarm
        self.body = body
        self.deleted = deleted
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, senderTenantId, senderUserId, mine, fromMyFarm, body, deleted, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderTenantId = try c.decodeIfPresent(String.self, forKey: .senderTenantId)
        senderUserId = try c.decodeIfPresent(String.self, forKey: .senderUserId)
        mine = try c.decode(Bool.self, forKey: .mine)
        fromMyFarm = try c.decodeIfPresent(Bool.self, forKey: .fromMyFarm) ?? false
        body = try c.decodeIfPresent(String.self, forKey: .body)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var speaker: MessageSpeaker { MessageSpeaker(mine: mine, fromMyFarm: fromMyFarm) }

    /// Removed, whichever of the two fields says so. A body that is null on a
    /// message not marked deleted is a contract break, and showing an empty
    /// bubble would be worse than showing it as removed.
    var isTombstone: Bool { deleted || body == nil }

    /// «Премахни» is offered only on MY OWN still-present messages. Since
    /// #1323 the server checks the sending PERSON and answers anyone else
    /// `MESSAGE_NOT_SENDER` — it used to compare the farm, so an admin could
    /// retract the creator's words. A colleague's message is not offered.
    var mayRetract: Bool { mine && !isTombstone }
}

/// Who said it, seen from the person holding the phone.
///
/// A pure mapping of the server's two flags, so the bubble's style, its
/// caption and its VoiceOver sentence all read one value, and a test can
/// hold every combination.
enum MessageSpeaker: Equatable, Sendable, CaseIterable {
    /// The person holding the phone.
    case me
    /// Someone else at the same farm who is in this conversation's audience.
    case colleague
    /// The other side of the listing — whoever there is writing.
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

    /// The caption over a bubble, and the first thing VoiceOver says.
    ///
    /// «Вие» is the PERSON since #1323, never the farm. The colleague has no
    /// name because the payload carries none — only an opaque id — so the
    /// caption says what is known. A sender name is a server follow-up
    /// (PARITY Gap 7).
    var label: String {
        switch self {
        case .me: "Вие"
        case .colleague: "Колега от стопанството"
        case .counterparty: "Отсрещната страна"
        }
    }

    /// My farm's side — me and a colleague — sits on the trailing edge, the
    /// other side on the leading one. A colleague DID write for my farm, so
    /// they are told apart from me by caption and bubble style, not by side.
    var isOurSide: Bool { self != .counterparty }
}

// MARK: - Write bodies and responses

/// `POST …/threads/{threadId}/messages`.
///
/// The spec says `maxLength: 8000`; the usecase refuses anything over 4000
/// UTF-16 units after sanitising and trimming (`MESSAGE_TOO_LONG`). The
/// composer enforces the real one — see `MessageBody`.
struct SendExchangeMessage: Encodable, Equatable, Sendable {
    let body: String
}

/// 201 from `POST …/listings/{listingId}/thread` (and 200 when the thread
/// already existed — `APIClient` returns both the same way, so `created` is
/// the only way to tell them apart).
struct ExchangeThreadOpened: Decodable, Equatable, Sendable {
    let id: String
    let created: Bool

    private enum CodingKeys: String, CodingKey { case id, created }

    init(id: String, created: Bool) {
        self.id = id
        self.created = created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decodeIfPresent(Bool.self, forKey: .created) ?? false
    }
}

/// 201 from a send. `id` is the only field a caller needs; the rest shape
/// what the screen says next.
///
/// The response does NOT echo the stored text — the sanitiser may have
/// changed it — so the conversation is refetched after a send rather than
/// patched from the draft.
struct ExchangeMessageSent: Decodable, Equatable, Sendable {
    let id: String
    let createdAt: Date?

    /// The thread was closed and this message reopened it: clear the local
    /// closed state. Always false on a replay, even if the original reopened.
    let reopened: Bool

    /// The `Idempotency-Key` matched an earlier send and this is the ORIGINAL
    /// message. Delivered, not duplicated — treat it exactly like a first send.
    let replayed: Bool

    private enum CodingKeys: String, CodingKey { case id, createdAt, reopened, replayed }

    init(id: String, createdAt: Date?, reopened: Bool, replayed: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.reopened = reopened
        self.replayed = replayed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        reopened = try c.decodeIfPresent(Bool.self, forKey: .reopened) ?? false
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

/// 200 from `POST …/read`. The pointer moves to the SERVER's now, and never
/// backwards. Required, because it is what decides whether to refetch — see
/// `ReadMarking.needsRefetch`.
struct ExchangeThreadRead: Decodable, Equatable, Sendable {
    let readAt: Date
}

/// 200 from `POST …/close`. An already-closed thread answers with its
/// ORIGINAL `closedAt` and `alreadyClosed: true` — still a success.
struct ExchangeThreadClosed: Decodable, Equatable, Sendable {
    let closedAt: Date?
    let alreadyClosed: Bool

    private enum CodingKeys: String, CodingKey { case closedAt, alreadyClosed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        alreadyClosed = try c.decodeIfPresent(Bool.self, forKey: .alreadyClosed) ?? false
    }
}

/// 200 from `POST …/block`. `blocked` is always true here; it is required
/// because it is the state the screen takes, and a body that did not say so
/// is not one to act on.
struct ExchangePartyBlocked: Decodable, Equatable, Sendable {
    let blocked: Bool
    let alreadyBlocked: Bool

    private enum CodingKeys: String, CodingKey { case blocked, alreadyBlocked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocked = try c.decode(Bool.self, forKey: .blocked)
        alreadyBlocked = try c.decodeIfPresent(Bool.self, forKey: .alreadyBlocked) ?? false
    }
}

/// 200 from `DELETE …/block`: always `{blocked: false}`, idempotent, with no
/// "was it blocked" field.
struct ExchangePartyUnblocked: Decodable, Equatable, Sendable {
    let blocked: Bool
}

/// 200 from `DELETE …/messages/{messageId}` — also for a message already
/// retracted. A soft delete: the server keeps the body and returns a
/// tombstone in its place from now on.
struct ExchangeMessageRetracted: Decodable, Equatable, Sendable {
    let id: String
}
