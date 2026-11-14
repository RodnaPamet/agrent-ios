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
    /// One post by id (agri-saas #3030): the post a permalink names, its
    /// channel, and its parent when it is a reply. A removed post answers 200
    /// collapsed, since a link can predate the removal.
    static func onePostPath(_ postID: String) -> String { "/api/social/channel-posts/\(URLEscape.segment(postID))" }
    static func joinPath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/join" }
    /// Moves the person's read cursor to NOW (agri-saas #2990). No body: the
    /// server takes its own clock, so a phone with a wrong one cannot park
    /// the cursor in the future.
    static func readPath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/read" }
    /// Muting stops the mention and reply PUSH in this channel (#601,
    /// agri-saas #3050). From the next post on: a push already on its way is
    /// not withdrawn.
    static func mutePath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/mute" }
    /// A photo or a voice note as a post (P9.6, agri-saas #3045).
    static func mediaPath(_ channelID: String) -> String { "\(listPath)/\(URLEscape.segment(channelID))/media" }
    /// The bytes, for MEMBERS only: a non-member reads the post and gets a
    /// 404 here, by design (a recording carries the speaker's voice).
    static func attachmentPath(_ postID: String) -> String {
        "/api/social/channel-posts/\(URLEscape.segment(postID))/attachment"
    }

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

    /// One post carrying a photo or a voice note, with an optional caption.
    /// The field name says which; the server checks the type by its bytes.
    /// NOT FIRED from tests, CI or A11yShots.
    static func postMedia(_ channelID: String, _ media: ChannelMedia, caption: String) async throws {
        var fields: [String: String] = [:]
        if !caption.isEmpty { fields["body"] = caption }
        if let durationMs = media.durationMs { fields["durationMs"] = String(durationMs) }
        _ = try await APIClient.shared.postMultipart(
            mediaPath(channelID), file: media.data, fileName: media.fileName, mimeType: media.mimeType,
            fields: fields, fileField: media.field)
    }

    static func post(_ postID: String) async throws -> PostLookup {
        let data = try await APIClient.shared.data(for: onePostPath(postID))
        return try await APIClient.shared.decode(data, as: PostLookup.self)
    }

    struct PostLookup: Decodable, Sendable {
        let post: ChannelPost
        let channelId: String
        let parentPostId: String?
    }

    static func attachment(_ postID: String) async throws -> Data {
        try await APIClient.shared.data(for: attachmentPath(postID))
    }

    /// The person's own act, from an open feed only: never from tests, CI or
    /// A11yShots.
    static func markRead(_ channelID: String) async throws {
        _ = try await APIClient.shared.postReturningData(readPath(channelID), body: EmptyBody(), idempotencyKey: nil)
    }

    /// The person's own act: never from tests, CI or A11yShots. Idempotent
    /// both ways.
    static func setMuted(_ channelID: String, _ muted: Bool) async throws {
        if muted {
            _ = try await APIClient.shared.postReturningData(mutePath(channelID), body: EmptyBody(), idempotencyKey: nil)
        } else {
            _ = try await APIClient.shared.deleteReturningData(mutePath(channelID))
        }
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
    /// Mention and reply pushes switched off (#601). Nil when not joined.
    let muted: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, key, nameBg, memberCount, slowModeSeconds, joined, banned, unreadCount, muted
    }
    init(id: String, key: String, nameBg: String, memberCount: Int?, slowModeSeconds: Int?, joined: Bool, banned: Bool,
         unreadCount: Int? = nil, muted: Bool? = nil) {
        self.id = id
        self.key = key
        self.nameBg = nameBg
        self.memberCount = memberCount
        self.slowModeSeconds = slowModeSeconds
        self.joined = joined
        self.banned = banned
        self.unreadCount = unreadCount
        self.muted = muted
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
        muted = try? c.decodeIfPresent(Bool.self, forKey: .muted)
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
        /// The handle of the farm the author posted AS, only where that farm
        /// has a published page (agri-saas #3043) — what makes «Пиши»
        /// possible from a post. A message to it reaches the farm's active
        /// OWNER, not necessarily this author.
        var farmHandle: String? = nil
    }

    /// A photo or a voice note (P9.6). The post's body may then be empty
    /// with `deleted: false` — the attachment IS the content; an empty body
    /// with `deleted: true` is a removed post.
    let attachment: Attachment?

    struct Attachment: Decodable, Equatable, Hashable, Sendable {
        let mime: String?
        let bytes: Int?
        let durationMs: Int?

        var isVoice: Bool { mime?.hasPrefix("audio/") == true || durationMs != nil }
    }

    var isQuestion: Bool { kind == "QUESTION" }

    private enum CodingKeys: String, CodingKey {
        case id, authorUserId, body, kind, createdAt, deleted, resolvedAt, replyCount, author, attachment
    }
    init(id: String, authorUserId: String, body: String, kind: String, createdAt: Date, deleted: Bool,
         resolvedAt: Date?, replyCount: Int, author: Author? = nil, attachment: Attachment? = nil) {
        self.id = id
        self.authorUserId = authorUserId
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
        self.deleted = deleted
        self.resolvedAt = resolvedAt
        self.replyCount = replyCount
        self.author = author
        self.attachment = attachment
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
        // A removed post serves no bytes, so it carries no attachment here.
        attachment = deleted ? nil : (try? c.decodeIfPresent(Attachment.self, forKey: .attachment)) ?? nil
    }
}

/// What a composer sends as a post's media (P9.6).
struct ChannelMedia: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case photo, voice(durationMs: Int) }
    let kind: Kind
    let data: Data

    var field: String { if case .voice = kind { "voice" } else { "photo" } }
    var durationMs: Int? { if case .voice(let ms) = kind { ms } else { nil } }
    var fileName: String { if case .voice = kind { "glas.m4a" } else { "snimka.jpg" } }
    var mimeType: String { if case .voice = kind { "audio/mp4" } else { "image/jpeg" } }

    /// The server's ceiling for a voice note (1.5 MB) — the real bound on
    /// «до 2:00», since it measures bytes, not seconds.
    static let maxVoiceBytes = 1_500_000
    static let maxVoiceMs = 120_000

    /// A LOCATION atom in an audio file: `©xyz` (Apple's) or `loci` (3GPP).
    /// The server refuses one (agri-saas #3044); this says so before upload.
    /// Encoder tags (`©too`) are not location and are left alone.
    ///
    /// Walks the BOX TREE rather than searching the bytes: four bytes that
    /// spell `loci` occur by chance inside a megabyte of audio often enough
    /// to refuse an honest recording, and a box header cannot.
    static func carriesLocation(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "udta", "meta", "ilst"]
        func walk(_ start: Int, _ end: Int, depth: Int) -> Bool {
            var offset = start
            while depth < 8, offset + 8 <= end {
                var size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let type = String(decoding: bytes[(offset + 4)..<(offset + 8)].map { $0 == 0xA9 ? 0x40 : $0 }, as: UTF8.self)
                var header = 8
                if size == 1, offset + 16 <= end {
                    size = Int(bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                    header = 16
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= header, offset + size <= end else { return false }
                if type == "@xyz" || type == "loci" { return true }
                if containers.contains(type) {
                    // `meta` is a full box: a version and flags first.
                    let inner = offset + header + (type == "meta" ? 4 : 0)
                    if walk(inner, offset + size, depth: depth + 1) { return true }
                }
                offset += size
            }
            return false
        }
        return walk(0, bytes.count, depth: 0)
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
