import Foundation

/// Everything environment-specific, in one place.
///
/// `redirectURI`'s scheme must ALSO be registered in Info.plist under
/// CFBundleURLTypes, and must appear in the server's
/// `NATIVE_AUTH_REDIRECT_ALLOWLIST`. All three have to agree or sign-in fails
/// with `redirect_uri_not_allowed` — see README, "Before the app can sign in".
enum Config {
    static let baseURL = URL(string: "https://app.agrent.bg")!

    /// The farm every tenant-scoped path is built for — app.agrent.bg/t/<slug>/…
    /// — and since agrent-ios#179 that is the ACTIVE farm, which `FarmStore`
    /// chooses and `ActiveFarm` mirrors for code that is not on the main actor.
    ///
    /// With no farm active it falls back to `legacyTenantSlug`. No screen
    /// reaches that: `FarmGate` shows nothing tenant-scoped without a farm.
    /// It is there so a path built in a test, or by a read that outlives a
    /// sign-out, goes where it always went instead of to `/api/t//`.
    static var tenantSlug: String { ActiveFarm.shared.farm?.slug ?? legacyTenantSlug }

    /// The farm the app was pinned to until #179. Every queued record written
    /// before records carried their farm belongs to it (`PendingOperation
    /// .tenant`), and a person signed in when this build first ran keeps it
    /// (`FarmMemory.seedLegacyFarmOnce`), so nobody's screen changes under them.
    static let legacyTenantSlug = "agrent"

    static let redirectScheme = "bg.agrent.app"
    static let redirectURI = "\(redirectScheme)://auth/callback"
}
