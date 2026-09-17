import Foundation

/// Everything environment-specific, in one place.
///
/// `redirectURI`'s scheme must ALSO be registered in Info.plist under
/// CFBundleURLTypes, and must appear in the server's
/// `NATIVE_AUTH_REDIRECT_ALLOWLIST`. All three have to agree or sign-in fails
/// with `redirect_uri_not_allowed` — see README, "Before the app can sign in".
enum Config {
    static let baseURL = URL(string: "https://app.agrent.bg")!

    /// The tenant slug from the web URL: app.agrent.bg/t/<slug>/journal
    /// Hard-coded for the slice; a real build reads it from /api/auth/me.
    static let tenantSlug = "agrent"

    static let redirectScheme = "bg.agrent.app"
    static let redirectURI = "\(redirectScheme)://auth/callback"
}
