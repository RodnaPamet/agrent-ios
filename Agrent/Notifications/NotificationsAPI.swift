import Foundation

/// «Известия» (#471): the server's notifications for the signed-in person,
/// the web's bell. 13 of the server's 16 producers write only here, never a
/// push (agri-saas #2510), so without this list they reached an iPhone
/// nowhere: a buyer's message on Борса, low stock, a lease about to end.
///
/// ── Read live, never cached on disk ──
///
/// A row names people («Петър ви възложи …»), as messaging does, so it is
/// read live and never goes through `ResponseCache`.
enum NotificationsAPI {
    private static var base: String { "\(FarmPath.root)/notifications" }

    /// The 50 NEWEST, newest first, as a bare array. The cap is silent on the
    /// server, so a read of exactly 50 says so on the page.
    static var listPath: String { base }
    /// Marks one read: a PUT with an empty body, read being the only change.
    static func readPath(_ id: String) -> String { "\(base)/\(URLEscape.segment(id))" }

    static let cap = 50

    static func list() async throws -> [AppNotification] {
        try await decodeList(from: APIClient.shared.data(for: listPath))
    }

    /// A row without an `id` is dropped, not the list.
    static func decodeList(from data: Data) async throws -> [AppNotification] {
        try await APIClient.shared.decode(data, as: [Lossy].self).compactMap(\.value)
    }

    private struct Lossy: Decodable, Sendable {
        let value: AppNotification?
        init(from decoder: any Decoder) throws { value = try? AppNotification(from: decoder) }
    }

    static func markRead(_ id: String) async throws {
        _ = try await APIClient.shared.putReturningData(readPath(id), body: EmptyBody())
    }

    private struct EmptyBody: Encodable, Sendable {}
}

/// One notification, as the server rendered it in the person's language
/// (agri-saas #2492/#2490): the phone shows `title` and `message` as they
/// are and composes nothing from `type`, the same as a push.
struct AppNotification: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let type: String?
    let title: String
    let message: String?
    /// Where it leads (agri-saas #2512): a root-relative path, the push's
    /// `link`, opened where the app can show it (`PushLink`); or an absolute
    /// https address a farm's own automation rule wrote, opened in Safari's
    /// view (`webPage`). Otherwise the row is only marked read.
    let linkUrl: String?
    let read: Bool
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, type, title, message, linkUrl, read, createdAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = (try? c.decodeIfPresent(String.self, forKey: .title))?.recorded ?? "Известие"
        message = (try? c.decodeIfPresent(String.self, forKey: .message))?.recorded
        linkUrl = try? c.decodeIfPresent(String.self, forKey: .linkUrl)
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    init(id: String, type: String?, title: String, message: String?, linkUrl: String?, read: Bool, createdAt: Date?) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.linkUrl = linkUrl
        self.read = read
        self.createdAt = createdAt
    }

    func markedRead() -> AppNotification {
        AppNotification(id: id, type: type, title: title, message: message, linkUrl: linkUrl, read: true, createdAt: createdAt)
    }

    /// Where it leads, when the app can show it. `farm` is the farm the list
    /// was read for, which resolves the one unprefixed task link (#473). An
    /// absolute address on this app's own server is read as its path, so a
    /// rule that wrote the whole address of a task still opens the task.
    func link(inFarm farm: String?) -> PushLink? {
        PushLink.parse(Self.ownPath(linkUrl) ?? linkUrl, inFarm: farm)
    }

    /// A page outside what the app shows, for Safari's view: an absolute
    /// https address, for example a document a farm's automation rule links
    /// to (#488). https only, never another scheme, and never an address
    /// carrying a user or password, where what reads as the host
    /// (`https://app.agrent.bg@…`) is not the host.
    func webPage(inFarm farm: String?) -> URL? {
        guard link(inFarm: farm) == nil, let linkUrl,
              let components = URLComponents(string: linkUrl),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              let url = components.url, InAppBrowser.opens(url) else { return nil }
        return url
    }

    /// `/path?query#fragment` of an https address on `Config.baseURL`'s
    /// host, or nil for anything else.
    private static func ownPath(_ link: String?) -> String? {
        guard let link, var components = URLComponents(string: link),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == Config.baseURL.host?.lowercased(),
              components.port == nil, components.user == nil, components.password == nil
        else { return nil }
        components.scheme = nil
        components.host = nil
        return components.string
    }
}
