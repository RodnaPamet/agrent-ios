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

    /// As a person reads it: host and path, no scheme. «app.agrent.bg/f/pobeda»
    /// is what goes on a card or into a message.
    static func displayAddress(handle: String) -> String {
        (url(handle: handle)?.host() ?? "") + pagePrefix + handle
    }
}
