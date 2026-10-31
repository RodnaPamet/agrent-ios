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
/// `/t/{slug}/assets/{id}`). Each becomes a case here once the app has a
/// screen for it. A guess at what an unknown path means would open the
/// wrong thing. Backend 1 listed every producer's link on agri-saas #2510.
///
/// ── A Борса conversation (#473) ──
///
/// `exchange-messaging.ts` writes `/t/{slug}/exchange/threads/{threadId}`,
/// first on the owner's approved push list (2026-10-30), and in «Известия».
///
/// ── The one unprefixed task link, in the list only ──
///
/// `field-operation.ts` writes `/farm-tasks/{taskId}`, with no farm (being
/// fixed as agri-saas #2512). «Известия» reads one farm's list, so it can
/// say which farm (`inFarm`). A push can't: its payload names no other
/// farm, and on a phone in two farms a guess opens the wrong farm's task.
/// So without `inFarm` the unprefixed form is no link, as before.
///
/// ── A block, and a listing (#475) ──
///
/// The agro warnings (spray window, disease risk) write
/// `/t/{slug}/locations/{locationId}`: that block's map. A new interest or
/// inquiry on a listing writes `/t/{slug}/exchange/my-interests#listing-{id}`
/// or `my-listings#listing-{id}`, the listing named in the FRAGMENT (kept so
/// web bookmarks keep working, backend 1 on #2510): that listing.
enum PushLink: Equatable, Sendable {
    case task(farm: String, id: String)
    case thread(farm: String, id: String)
    case location(farm: String, id: String)
    case listing(farm: String, id: String)

    /// nil for no link, an absolute URL (never followed: the server sends
    /// paths, so anything else did not come from it), or a path the app
    /// can't show.
    static func parse(_ link: String?, inFarm listFarm: String? = nil) -> PushLink? {
        guard let link, link.hasPrefix("/"), !link.hasPrefix("//"),
              let components = URLComponents(string: link) else { return nil }
        // `path` is decoded, which splits on the separators the server
        // wrote, not ones a percent-encoded id might contain.
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        func decoded(_ part: String) -> String? {
            part.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard parts.first?.isEmpty == true else { return nil }
        if parts.count == 5, parts[1] == "t", parts[3] == "farm-tasks",
           let farm = decoded(parts[2]), let id = decoded(parts[4]) {
            return .task(farm: farm, id: id)
        }
        if parts.count == 5, parts[1] == "t", parts[3] == "locations",
           let farm = decoded(parts[2]), let id = decoded(parts[4]) {
            return .location(farm: farm, id: id)
        }
        if parts.count == 5, parts[1] == "t", parts[3] == "exchange",
           parts[4] == "my-listings" || parts[4] == "my-interests",
           let farm = decoded(parts[2]),
           let fragment = components.fragment, fragment.hasPrefix("listing-"),
           let id = decoded(String(fragment.dropFirst("listing-".count))) {
            return .listing(farm: farm, id: id)
        }
        if parts.count == 6, parts[1] == "t", parts[3] == "exchange", parts[4] == "threads",
           let farm = decoded(parts[2]), let id = decoded(parts[5]) {
            return .thread(farm: farm, id: id)
        }
        if let listFarm, !listFarm.isEmpty, parts.count == 3, parts[1] == "farm-tasks", let id = decoded(parts[2]) {
            return .task(farm: listFarm, id: id)
        }
        return nil
    }

    /// The farm the link is in.
    var farm: String {
        switch self {
        case .task(let farm, _), .thread(let farm, _), .location(let farm, _), .listing(let farm, _): farm
        }
    }
}
