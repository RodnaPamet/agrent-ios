import SafariServices
import SwiftUI

/// A web page in a sheet, without leaving the app.
///
/// For pages that only exist on the web: a farm's public page (#323), which
/// the server renders as HTML and serves no JSON for. Safari's own view, not
/// a `WKWebView`. It brings its reader, share and «Done» controls, and the
/// page sees Safari's cookies, not this app's session, which is right for a
/// public page.
///
/// UIKit because SwiftUI has no in-app browser before iOS 26
/// (`OpenURLAction.Result.systemAction(prefersInApp:)`), and this app
/// supports iOS 17.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    /// Safari's view takes only http and https, and raises on anything else.
    /// A caller checks first, so a bad link becomes nothing rather than a crash.
    /// `nonisolated`: a representable is the main actor's, and this is a pure
    /// check on a value that the tests call directly.
    nonisolated static func opens(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .close
        browser.preferredControlTintColor = UIColor(Palette.accent)
        return browser
    }

    func updateUIViewController(_ browser: SFSafariViewController, context: Context) {}
}
