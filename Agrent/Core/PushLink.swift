import Foundation

/// What a tapped notification names, read from its `link` (agrent-ios#368).
///
/// ── The server's shape ──
///
/// agri-saas #2076 puts the notification's `linkUrl` beside `aps` as `link`,
/// unchanged and ROOT-RELATIVE, as every web link it builds:
/// `/t/{slug}/farm-tasks/{id}` for a task assigned to the person
/// (`notifications/assignment.ts`), the one notification sent to phones
/// today. The server owns the shape, so a path the phone doesn't know yet is
/// not an error. The app opens as it is.
///
/// ── Only what the app can show ──
///
/// Other paths are built the same way (`/t/{slug}/locations/{id}`,
/// `/t/{slug}/assets/{id}`), and are not sent to phones yet. Each becomes a
/// case here once it is, with the screen it opens. A guess at what an
/// unknown path means would open the wrong thing.
enum PushLink: Equatable, Sendable {
    case task(farm: String, id: String)

    /// nil for no link, an absolute URL (never followed: the server sends
    /// paths, so anything else did not come from it), or a path the app
    /// can't show.
    static func parse(_ link: String?) -> PushLink? {
        guard let link, link.hasPrefix("/"), !link.hasPrefix("//"),
              let components = URLComponents(string: link) else { return nil }
        // `path` is decoded, which splits on the separators the server
        // wrote, not ones a percent-encoded id might contain.
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "t", parts[3] == "farm-tasks",
              let farm = parts[2].removingPercentEncoding, !farm.isEmpty,
              let id = parts[4].removingPercentEncoding, !id.isEmpty else { return nil }
        return .task(farm: farm, id: id)
    }

    /// The farm the link is in.
    var farm: String {
        switch self {
        case .task(let farm, _): farm
        }
    }
}
