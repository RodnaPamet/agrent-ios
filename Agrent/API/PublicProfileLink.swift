import Foundation

/// The address of a farm's public page, `/f/{handle}` on the app's host:
/// a web page opened in Safari and shared, never requested by this app,
/// so not an API path (`RouteContractTests.notAPIPaths`).
///
/// The same URL the web's share kit builds (`publicProfileUrl`, agri-saas
/// #1885): a copied link, a forward and a printed QR all reach one address.
enum PublicProfileLink {
    private static let pagePrefix = "/f/"

    static func url(handle: String) -> URL? {
        URL(string: pagePrefix + URLEscape.segment(handle), relativeTo: Config.baseURL)?.absoluteURL
    }

    /// The handle a link to a farm's page names: `https://app.agrent.bg/f/{handle}`,
    /// ours only (the host is checked), one segment, nothing after it. Nil
    /// for every other link, so a link this phone has no screen for is left
    /// to the system.
    static func handle(from url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host()?.lowercased() == Config.baseURL.host()?.lowercased() else { return nil }
        let parts = url.path().split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "f" else { return nil }
        let handle = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        return handle.isEmpty ? nil : handle
    }

    /// As a person reads it: host and path, no scheme. «app.agrent.bg/f/pobeda»
    /// is what goes on a card or into a message.
    static func displayAddress(handle: String) -> String {
        (url(handle: handle)?.host() ?? "") + pagePrefix + handle
    }
}
