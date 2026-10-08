import Foundation

/// Everything environment-specific, in one place.
///
/// `redirectURI`'s scheme must ALSO be registered in Info.plist under
/// CFBundleURLTypes, and must appear in the server's
/// `NATIVE_AUTH_REDIRECT_ALLOWLIST`. All three have to agree or sign-in fails
/// with `redirect_uri_not_allowed` — see README, "Before the app can sign in".
enum Config {
    static let baseURL = URL(string: "https://app.agrent.bg")!

    /// The farm the app was pinned to until #179 — and since #192 (P4.3)
    /// never a path's fallback, nor anybody's starting farm: a farm path is
    /// built from the OPEN farm or from none (`FarmPath`). What is left of it
    /// is a migration and a fixture, and a CI guard keeps it to those files:
    ///
    /// - every queued record written before records carried their farm
    ///   belongs to it (`PendingOperation.tenant`);
    /// - the UI-test seam's fixture world is this one farm.
    static let pinnedFarmSlug = "agrent"

    static let redirectScheme = "bg.agrent.app"
    static let redirectURI = "\(redirectScheme)://auth/callback"
}
