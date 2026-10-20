import Foundation
import os

/// Which APNs host this install's token works against (agrent-ios#355;
/// agri-saas #1764 step 3). Sent as `environment` with every registration.
///
/// ── Why the phone has to say ──
///
/// A development-signed install (every build installed from this Mac) gets a
/// token that works only against `api.sandbox.push.apple.com`. A TestFlight
/// or App Store one works only against the production host. One server sends
/// to both kinds, and the token itself doesn't say which it is. Sent to the
/// wrong host it fails as `BadDeviceToken`, the same answer as a revoked
/// token, and the server prunes a revoked token's row.
///
/// ── Read from the provisioning profile ──
///
/// The `aps-environment` entitlement is in `embedded.mobileprovision`.
/// Development and ad hoc installs carry one; the App Store strips it, so
/// an install without one is TestFlight or the App Store, which is
/// production.
///
/// A profile that is there but can't be read sends nothing rather than a
/// guess. The server stores the gap, refuses to send to it and logs it
/// (backend 2, 2026-10-20), where a wrong guess would cost the registration.
enum APNsEnvironment: String, Encodable, Equatable, Sendable {
    // The wire's words, lower-case; the server maps them to its enum.
    case development
    case production

    /// This install's, read once: the profile can't change under a running
    /// app.
    static let current: APNsEnvironment? = {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        let found = of(profileAt: url)
        if url != nil, found == nil {
            Log.auth.error("APNs environment unreadable from the provisioning profile; registering without it")
        }
        return found
    }()

    /// No profile is production. A profile is read for its entitlement.
    static func of(profileAt url: URL?) -> APNsEnvironment? {
        guard let url else { return .production }
        return of(profile: try? Data(contentsOf: url))
    }

    /// The profile's `Entitlements` → `aps-environment`, or `nil` when it
    /// can't be read or names neither host.
    ///
    /// The profile is a signed CMS envelope with the property list inside
    /// it as plain XML. Checking the signature is iOS's job at install, so
    /// this only finds the XML and parses it.
    static func of(profile data: Data?) -> APNsEnvironment? {
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let root = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return nil }
        return APNsEnvironment(rawValue: value)
    }
}
