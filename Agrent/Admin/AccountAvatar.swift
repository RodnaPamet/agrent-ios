import Foundation
import Observation
import UIKit

/// The signed-in account's uploaded picture — agri-saas `GET
/// /api/account/avatar/{userId}`.
///
/// ── Why this route, read from the server (agri-saas main, 2026-10-04) ──
///
/// `/api/auth/me` carries NO picture: its `select` is `id, email, name,
/// bottomTabOrder` and the membership, and `CurrentUser` in openapi.json has
/// no image field. `User.image` exists in the database but is never sent to
/// this app. `GET /api/account/avatar` (no id) has NO handler — that file is
/// POST (upload) and DELETE only. What remains is the serve route the web's
/// `avatarServeUrl(userId)` writes into `User.image` for an UPLOADED avatar:
///
///   · 200 — the bytes themselves, `image/webp`, streamed. No redirect, no
///           JSON, no presigned URL.
///   · 404 — this user never uploaded one. That is the ORDINARY answer, and
///           it means initials, not an error.
///   · 401 — no session. `auth()` falls back to the native bearer
///           (`resolveBearerSession`), so `APIClient`'s Authorization header
///           is what makes it answer at all — which is why this cannot be an
///           `AsyncImage`: that loads through `URLSession.shared`, sends no
///           bearer, and would get a 401 for every account.
///
/// Live and UNDOCUMENTED on the server's inventory (it is not in
/// openapi.json), which `RouteContractTests` tolerates and names.
///
/// ── What it does NOT cover, said so nobody wonders ──
///
/// An OAuth provider picture (`User.image` = a Google URL) is not reachable:
/// `/me` does not return `User.image`, and the serve route only streams what
/// was uploaded. Such an account shows initials here while the web shows its
/// Google photo. Closing that needs `/me` to send the image — a server change.
enum AccountAvatarAPI {
    /// Account-level, not tenant-scoped: no slug in the path, like `/me`.
    static func path(userID: String) -> String {
        "/api/account/avatar/\(URLEscape.segment(userID))"
    }

    /// Bytes → picture, or nil for anything that is not one.
    ///
    /// `UIImage(data:)` reads webp natively since iOS 14, so the server's
    /// format needs no decoder of ours. A zero-size result is refused too:
    /// an image the circle would draw as nothing is worse than initials.
    static func image(from data: Data) -> UIImage? {
        guard !data.isEmpty, let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}

/// The picture for the card on Админ, held IN MEMORY ONLY.
///
/// ── No disk, deliberately (#136) ──
///
/// Not `ResponseCache` and not `URLCache`: a face is personal data, and the
/// app's rule is that nothing it fetches lands in Cache.db. The bytes go
/// through `APIClient`, whose session has no `urlCache`; the decoded image
/// lives in this object and nowhere else. The cost is one small request
/// (~5–25 KB) per launch the first time Админ is opened — a monthly screen.
///
/// ── A singleton, so it is on the sign-out list ──
///
/// Held across Админ openings so the circle does not flash initials-then-
/// photo every time, which means it outlives the view and must be reset at
/// Изход (#142): B must never open Админ and see A's face, even for the
/// moment before B's own request answers. `SessionReset.resetUserState()`
/// calls `reset()`, and a request that started under A and answers after
/// Изход is dropped by the epoch guard in `load(for:)`.
@Observable
@MainActor
final class AccountAvatarStore {
    static let shared = AccountAvatarStore()

    enum Avatar: Equatable {
        /// Not asked yet, or the last ask failed for a reason that may pass
        /// (offline, a 5xx, the fixture seam's 501). Initials, and ask again
        /// next time.
        case unknown
        /// The server said this account has no picture (404), or sent bytes
        /// that are not one. Initials, and do not ask again this session.
        case none
        case image(UIImage)
    }

    /// WHOSE picture `avatar` is. Kept beside it so a different account can
    /// never be shown this one's face, even without a sign-out in between.
    private(set) var userID: String?
    private(set) var avatar: Avatar = .unknown

    /// The picture, for the view; nil means "draw initials".
    func image(for userID: String) -> UIImage? {
        guard self.userID == userID, case .image(let image) = avatar else { return nil }
        return image
    }

    @ObservationIgnored private var inFlight: String?
    /// The seam for `AccountCardTests`. The app's is `APIClient` — the bearer,
    /// the refresh-on-401, `ClientHeader.stamp`, the cache-less session and
    /// the fixture seam, all of which a picture request needs and none of
    /// which a hand-built `URLRequest` would get.
    @ObservationIgnored private let fetch: @MainActor (String) async throws -> Data

    init(fetch: @escaping @MainActor (String) async throws -> Data = {
        try await APIClient.shared.data(for: AccountAvatarAPI.path(userID: $0))
    }) {
        self.fetch = fetch
    }

    /// Ask once per account per session; a transient failure asks again.
    func load(for userID: String) async {
        if self.userID == userID, avatar != .unknown { return }
        if inFlight == userID { return }
        if self.userID != userID {
            self.userID = userID
            avatar = .unknown
        }
        inFlight = userID

        // Captured BEFORE the await: an answer for A that lands after Изход
        // must not become the picture B's Админ opens on.
        let epoch = SessionEpoch.current
        let result: Avatar?
        do {
            let data = try await fetch(userID)
            result = AccountAvatarAPI.image(from: data).map(Avatar.image) ?? Avatar.none
        } catch APIClient.APIError.http(404, _, _, _, _) {
            result = Avatar.none
        } catch {
            // Nothing logged here: `APIClient` already logged the status, and
            // there is nothing about the account worth adding to a log.
            result = nil
        }
        guard SessionEpoch.isCurrent(epoch), self.userID == userID else { return }
        inFlight = nil
        if let result { avatar = result }
    }

    /// Back to a fresh launch's state — part of `SessionReset`.
    func reset() {
        userID = nil
        avatar = .unknown
        inFlight = nil
    }

    #if DEBUG
    /// For `AccountCardTests`, which must seed the SHARED store (the one
    /// `SessionReset` empties) without its `APIClient` fetch.
    func adoptForTesting(userID: String, image: UIImage) {
        self.userID = userID
        avatar = .image(image)
    }
    #endif
}

/// One or two letters for the circle when there is no picture.
///
/// ── The web's rule, so the two clients draw the same letters ──
///
/// agri-saas `getInitials` (`initials-avatar.tsx`, the primitive behind the
/// web's user menu and member list): split on whitespace; one word gives its
/// first letter, more give the FIRST and the LAST word's — «Иван Петров
/// Иванов» is «ИИ», not «ИП». Uppercased in Bulgarian, which matters only in
/// principle (Cyrillic has no case trap like Turkish dotted i), but costs
/// nothing.
///
/// ── The email, when there is no name ──
///
/// Owner, 2026-10-04: the letters of the email when the name is missing. Only
/// the local part — the domain is the same for a whole farm and would give
/// everyone the same letter — split on the separators people put between
/// their names (`ivan.petrov`, `ivan_petrov`, `ivan-petrov`). A `+tag` is
/// dropped first: it is a mailbox filter, not a name.
///
/// `Character`, not `unicodeScalars.first`: a letter with a combining mark
/// («Й» written as И + U+0306) is ONE character and must stay whole.
enum AccountInitials {
    static func of(name: String?, email: String?) -> String? {
        if let fromName = letters(words(name, separators: .whitespacesAndNewlines)) {
            return fromName
        }
        let local = email?.split(separator: "@", omittingEmptySubsequences: false).first
            .map { String($0.split(separator: "+", omittingEmptySubsequences: false).first ?? "") }
        return letters(words(local, separators: CharacterSet(charactersIn: "._-")
                                .union(.whitespacesAndNewlines)))
    }

    private static func words(_ text: String?, separators: CharacterSet) -> [Substring] {
        guard let text else { return [] }
        return text.split { $0.unicodeScalars.allSatisfy(separators.contains) }
    }

    private static func letters(_ words: [Substring]) -> String? {
        guard let first = words.first?.first else { return nil }
        let picked = words.count > 1 ? [first, words[words.count - 1].first].compactMap { $0 } : [first]
        return String(picked).uppercased(with: Locale(identifier: "bg"))
    }
}
