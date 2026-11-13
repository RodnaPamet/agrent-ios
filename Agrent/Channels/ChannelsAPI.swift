import Foundation

/// «Канали» (P9.8, #583; owner 2026-11-12): the public topic channels every
/// farm shares, by crop, by oblast and by input. Contract: agri-saas #2986.
///
/// ── Not a farm's data ──
///
/// `/api/social/…` has no farm in its path: a channel has no tenant, and a
/// member of three farms sees the same channels under all three. The
/// server's MECHANISATOR confinement only engages on a tenant path, so every
/// role reaches these routes (#2986 §1).
///
/// ── What the server does not do yet, so the phone does not pretend ──
///
/// No realtime: the open feed polls. No unread counts until the server
/// writes a read cursor (owner chose to add one). No author names until the
/// server sends them (owner chose name + farm): a post never shows an id.
/// No mentions inbox and no mute: both are inert server-side (#2987).
/// Behind `social.channels`, off in production until the owner switches it.
enum ChannelsAPI {
    static let flag = "social.channels"

    static let listPath = "/api/social/channels"
    static func feedPath(_ channelID: String, before: Date? = nil, limit: Int = 50) -> String {
        var path = "\(listPath)/\(URLEscape.segment(channelID))?limit=\(limit)"
        if let before { path += "&before=\(cursor(before))" }
        return path
    }
    static func repliesPath(_ postID: String, after: Date? = nil, limit: Int = 50) -> String {
        var path = "/api/social/channel-posts/\(URLEscape.segment(postID))/replies?limit=\(limit)"
        if let after { path += "&after=\(cursor(after))" }
        return path
    }
    static func postPath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/posts" }
    static func replyPath(_ postID: String) -> String { "/api/social/channel-posts/\(URLEscape.segment(postID))/replies" }
    static func resolvedPath(_ postID: String) -> String { "/api/social/channel-posts/\(URLEscape.segment(postID))/resolved" }
    static func joinPath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/join" }

    /// The page cursor: the server's own ISO instant, percent-escaped (`+`
    /// and `:` in a query).
    static func cursor(_ date: Date) -> String {
        BgDate.isoInstant(date).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? BgDate.isoInstant(date)
    }

    static let maxBody = 4000

    static func channels() async throws -> [Channel] {
        let data = try await APIClient.shared.data(for: listPath)
        return try await APIClient.shared.decode(data, as: ChannelList.self).channels
    }

    static func feed(_ channelID: String, before: Date? = nil) async throws -> ChannelPage {
        let data = try await APIClient.shared.data(for: feedPath(channelID, before: before))
        return try await APIClient.shared.decode(data, as: ChannelPage.self)
    }

    static func replies(_ postID: String, after: Date? = nil) async throws -> ChannelPage {
        let data = try await APIClient.shared.data(for: repliesPath(postID, after: after))
        return try await APIClient.shared.decode(data, as: ChannelPage.self)
    }

    // MARK: - Writes (the person's own acts; never from tests, CI or A11yShots)

    /// `tenantSlug` (agri-saas #2989): the farm the post is made AS, the one
    /// open on the phone. Recorded at write time and never back-filled, so a
    /// post sent without it names no farm for ever. Channel routes carry no
    /// farm in their path; this is the only place it goes.
    struct NewPost: Encodable, Sendable {
        let body: String
        /// `POST` or `QUESTION`; the server refuses `CARD`.
        let kind: String
        let tenantSlug: String?
    }

    struct NewReply: Encodable, Sendable {
        let body: String
        let alsoToChannel: Bool
        let tenantSlug: String?
    }

    static func post(_ channelID: String, _ post: NewPost) async throws {
        _ = try await APIClient.shared.postReturningData(postPath(channelID), body: post, idempotencyKey: UUID().uuidString)
    }

    static func reply(_ postID: String, _ reply: NewReply) async throws {
        _ = try await APIClient.shared.postReturningData(replyPath(postID), body: reply, idempotencyKey: UUID().uuidString)
    }

    static func setResolved(_ postID: String, _ resolved: Bool) async throws {
        _ = try await APIClient.shared.putReturningData(resolvedPath(postID), body: ["resolved": resolved])
    }

    static func join(_ channelID: String) async throws {
        _ = try await APIClient.shared.postReturningData(joinPath(channelID), body: EmptyBody(), idempotencyKey: nil)
    }

    static func leave(_ channelID: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(joinPath(channelID))
    }

    private struct EmptyBody: Encodable, Sendable {}

    // MARK: - One's own display name (agri-saas #2989)

    /// GET says whether channels show a name for this person; PUT sets it.
    /// Behind `social.channels` like the rest: 404 while it is off.
    static let profilePath = "/api/social/profile"

    static func profile() async throws -> PersonName {
        let data = try await APIClient.shared.data(for: profilePath)
        return try await APIClient.shared.decode(data, as: PersonName.self)
    }

    /// Setting a name PUBLISHES it: giving it is the consent, which is why
    /// the prompt says where it will be seen (`ChannelWords.nameHint`).
    static func setDisplayName(_ name: String) async throws {
        _ = try await APIClient.shared.putReturningData(profilePath, body: ["displayName": name])
    }
}

/// A channel in the directory.
struct Channel: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    /// `crop:wheat`, `oblast:…`, `input:…`: the PREFIX groups it (#2986 §2).
    let key: String
    let nameBg: String
    let memberCount: Int?
    let slowModeSeconds: Int?
    /// The caller's own membership.
    let joined: Bool
    /// Shown, so a ban is never a silent refusal.
    let banned: Bool
    /// Joined channels only, once the server writes a read cursor.
    let unreadCount: Int?

    private enum CodingKeys: String, CodingKey { case id, key, nameBg, memberCount, slowModeSeconds, joined, banned, unreadCount }
    init(id: String, key: String, nameBg: String, memberCount: Int?, slowModeSeconds: Int?, joined: Bool, banned: Bool,
         unreadCount: Int? = nil) {
        self.id = id
        self.key = key
        self.nameBg = nameBg
        self.memberCount = memberCount
        self.slowModeSeconds = slowModeSeconds
        self.joined = joined
        self.banned = banned
        self.unreadCount = unreadCount
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        nameBg = try c.decode(String.self, forKey: .nameBg)
        memberCount = try? c.decodeIfPresent(Int.self, forKey: .memberCount)
        slowModeSeconds = try? c.decodeIfPresent(Int.self, forKey: .slowModeSeconds)
        joined = (try? c.decodeIfPresent(Bool.self, forKey: .joined)) ?? false
        banned = (try? c.decodeIfPresent(Bool.self, forKey: .banned)) ?? false
        unreadCount = try? c.decodeIfPresent(Int.self, forKey: .unreadCount)
    }
}

/// A post or a reply.
struct ChannelPost: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let authorUserId: String
    let body: String
    /// `POST`, `QUESTION`, `CARD`.
    let kind: String
    let createdAt: Date
    /// Retracted, removed or hidden: one state, by design (a disclosure
    /// rule), and the body is empty. Never told apart.
    let deleted: Bool
    let resolvedAt: Date?
    let replyCount: Int
    /// Name and farm (owner: name + farm; agri-saas #2989). Either half can
    /// be missing: the name is the person's PUBLISHED display name, and the
    /// farm is the one the post was made as. Null on a removed post.
    let author: Author?

    struct Author: Decodable, Equatable, Hashable, Sendable {
        let displayName: String?
        let farmName: String?
    }

    var isQuestion: Bool { kind == "QUESTION" }

    private enum CodingKeys: String, CodingKey { case id, authorUserId, body, kind, createdAt, deleted, resolvedAt, replyCount, author }
    init(id: String, authorUserId: String, body: String, kind: String, createdAt: Date, deleted: Bool,
         resolvedAt: Date?, replyCount: Int, author: Author? = nil) {
        self.id = id
        self.authorUserId = authorUserId
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
        self.deleted = deleted
        self.resolvedAt = resolvedAt
        self.replyCount = replyCount
        self.author = author
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        authorUserId = try c.decode(String.self, forKey: .authorUserId)
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "POST"
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        resolvedAt = try? c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        replyCount = (try? c.decodeIfPresent(Int.self, forKey: .replyCount)) ?? 0
        author = try? c.decodeIfPresent(Author.self, forKey: .author)
    }
}

/// One's own name in the channels. `displayName` is null whenever a channel
/// would show none: never set, cleared, or not published. That is the
/// prompt's whole signal.
struct PersonName: Decodable, Equatable, Sendable {
    let displayName: String?
    let published: Bool

    private enum CodingKeys: String, CodingKey { case displayName, published }
    init(displayName: String?, published: Bool) {
        self.displayName = displayName
        self.published = published
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = ((try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        published = (try? c.decodeIfPresent(Bool.self, forKey: .published)) ?? false
    }

    /// The composer asks for a name.
    var needsName: Bool { displayName == nil }
}

/// A page of posts (the feed, newest first) or replies (a thread, oldest
/// first): the two reads share the shape and differ in direction.
struct ChannelPage: Decodable, Equatable, Sendable {
    let posts: [ChannelPost]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey { case posts, replies, hasMore }
    init(posts: [ChannelPost], hasMore: Bool) {
        self.posts = posts
        self.hasMore = hasMore
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decode([ChannelLossy<ChannelPost>].self, forKey: .posts))
            ?? (try? c.decode([ChannelLossy<ChannelPost>].self, forKey: .replies)) ?? []
        posts = rows.compactMap(\.value)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
    }
}

private struct ChannelList: Decodable {
    let channels: [Channel]
    private enum CodingKeys: String, CodingKey { case channels }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = ((try? c.decode([ChannelLossy<Channel>].self, forKey: .channels)) ?? []).compactMap(\.value)
    }
}

/// One bad row costs that row, never the list.
private struct ChannelLossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
