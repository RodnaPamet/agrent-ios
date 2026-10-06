import Foundation
import ImageIO
import Observation
import UIKit

/// The signed-in account's picture, from `/me`'s `avatarUrl` (agri-saas
/// #1299, merged as #1316 — main a3df5f0).
///
/// ── What the server sends, read from the spec and `/api/auth/me` ──
///
/// `avatarUrl` is a STRAIGHT PROJECTION of `User.image`: no fallback chain,
/// no existence probe. The write path has already collapsed every case into
/// that one column, so it arrives in exactly one of three shapes:
///
///   · null      — no picture. Initials, and NO request: the old build asked
///                 the serve route by user id on the off chance, and got a
///                 404 for most accounts.
///   · ROOT-RELATIVE (`/api/account/avatar/<id>`) — uploaded through the
///                 API. `getUserAvatar`: webp bytes, needs THIS APP'S BEARER,
///                 404 once removed. Goes through `APIClient` — the bearer,
///                 refresh-on-401, `ClientHeader`, the cache-less session.
///   · ABSOLUTE `https://` on a THIRD-PARTY host — an OAuth provider photo
///                 (Google). Fetched as given with NO credentials: the
///                 bearer on that request would hand this account's session
///                 to someone else's CDN. `NoURLCache.thirdPartySession`, no
///                 cookies, no credential store, no `Authorization`.
///
/// The server returns the value as stored ON PURPOSE — absolutising the
/// relative one would hide which host is about to be contacted — so the
/// branch here is the whole security decision, and it is pure and tested.
enum AccountAvatarAPI {
    /// Where a picture comes from, with the credential decision made.
    enum Source: Hashable, Sendable {
        /// Root-relative, on the API host, with the bearer.
        case api(path: String)
        /// Absolute https on someone else's host, with nothing.
        case external(URL)
    }

    /// `avatarUrl` → where to fetch it, or nil for "draw initials, ask
    /// nothing".
    ///
    /// Refused (nil), so they fall back to initials rather than to a guess:
    ///
    ///   · `//host/…` and `/\…` — they start with a slash but a URL parser
    ///     reads them as ANOTHER HOST, which is exactly the bearer leak the
    ///     relative branch must never become. `APIClient.url(for:)` would
    ///     pin them to the API host anyway; refusing them says so out loud.
    ///   · a path `APIClient.url(for:)` will not build (raw spaces etc.).
    ///   · any absolute URL that is not `https` — `http` would send the
    ///     request in clear (and ATS refuses it), `data:`/`file:` are not a
    ///     picture on a server at all.
    ///   · an absolute URL with a user or password in it: credentials the
    ///     server did not mean to hand us, on a request that must carry none.
    static func source(_ avatarURL: String?) -> Source? {
        guard let raw = avatarURL, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") {
            guard !raw.hasPrefix("//"), !raw.contains("\\"),
                  (try? APIClient.url(for: raw)) != nil else { return nil }
            return .api(path: raw)
        }
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return .external(url)
    }

    /// The request for a THIRD-PARTY picture. Stamped like every request
    /// (house rule; `ClientHeaderTests` scans for it), and deliberately
    /// WITHOUT `Authorization` and without cookies.
    static func externalRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        ClientHeader.stamp(&req)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        return req
    }

    /// Five megabytes. The server's own uploads are small webp (~5–25 KB) and
    /// a provider photo is a thumbnail, so anything near this is not an
    /// avatar — and the bytes are held in memory, so the cap is what keeps a
    /// hostile or broken host from filling it.
    static let maxBytes = 5 * 1024 * 1024

    /// Refused before decoding: a small file can DECLARE enormous dimensions,
    /// and a full decode allocates width × height × 4 bytes.
    static let maxSourcePixels = 40_000_000

    /// The longest side kept after decoding. The circle is 52 pt, scaled with
    /// Dynamic Type to roughly three times that at the largest accessibility
    /// size, on a 3× screen — about 470 px. Larger would be memory spent on
    /// pixels nobody sees.
    static let maxPixelSize = 640

    /// Why a fetch ended without bytes, when the answer is FINAL for this
    /// value — as opposed to offline or a 5xx, which may pass.
    enum Unavailable: Error, Equatable {
        /// The host answered, and not with a picture (404, 410, 403…).
        case gone(status: Int)
        /// More than `maxBytes`, by the header or by counting.
        case tooLarge
    }

    /// GET a third-party picture with no credentials, stopping at `maxBytes`.
    ///
    /// Streamed and counted rather than `data(for:)`: a missing or lying
    /// `Content-Length` must not let the whole body into memory before the
    /// cap is checked.
    static func fetchExternal(_ url: URL) async throws -> Data {
        let (bytes, response) = try await NoURLCache.thirdPartySession.bytes(for: externalRequest(for: url))
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200: break
        case 400..<500 where http.statusCode != 408 && http.statusCode != 429:
            bytes.task.cancel()
            throw Unavailable.gone(status: http.statusCode)
        default:
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw Unavailable.tooLarge
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw Unavailable.tooLarge
            }
        }
        return data
    }

    /// Bytes → picture, or nil for anything that is not one.
    ///
    /// ImageIO rather than `UIImage(data:)`: it reads the declared size
    /// first (refused above `maxSourcePixels`) and DOWNSAMPLES to
    /// `maxPixelSize` while decoding, so a picture costs what the circle
    /// shows, not what the file claims. webp is read natively (iOS 14+), so
    /// the server's format needs no decoder of ours. A zero-size result is
    /// refused too: an image the circle would draw as nothing is worse than
    /// initials.
    static func image(from data: Data) -> UIImage? {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maxSourcePixels
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cgImage.width > 0, cgImage.height > 0 else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The picture for the account card (Админ and Профил), held IN MEMORY ONLY.
///
/// ── No disk, deliberately (#136) ──
///
/// Not `ResponseCache` and not `URLCache`: a face is personal data, and the
/// app's rule is that nothing it fetches lands in Cache.db. Both sessions it
/// uses have no `urlCache`; the decoded image lives in this object and
/// nowhere else.
///
/// ── Keyed on the user AND the value of `avatarUrl` ──
///
/// The foreground `/me` refresh (#147) can change `avatarUrl` — an upload,
/// a removal, a first Google sign-in — and that change, and only that one,
/// fetches again. The same value is asked once per session; a picture held
/// for a different value is never shown, so a removed avatar turns back
/// into initials on the refresh that reports it, with no request.
///
/// ── A singleton, so it is on the sign-out list ──
///
/// Held across Админ openings so the circle does not flash initials-then-
/// photo every time, which means it outlives the view and must be reset at
/// Изход (#142): B must never open Админ and see A's face, even for the
/// moment before B's own request answers. `SessionReset.resetUserState()`
/// calls `reset()`, and a request that started under A and answers after
/// Изход is dropped by the epoch guard in `load(for:avatarURL:)`.
@Observable
@MainActor
final class AccountAvatarStore {
    static let shared = AccountAvatarStore()

    enum Avatar: Equatable {
        /// Not asked yet, or the last ask failed for a reason that may pass
        /// (offline, a 5xx, the fixture seam's 501). Initials, and ask again
        /// next time.
        case unknown
        /// The host said there is no picture there (404 and kin), or sent
        /// something that is not one or is too big. Initials, and do not ask
        /// again for this value.
        case none
        case image(UIImage)
    }

    /// WHOSE picture, from WHICH value. Kept beside `avatar` so a different
    /// account — or the same account after its picture changed — can never
    /// be shown this one.
    struct Key: Hashable {
        let userID: String
        let source: AccountAvatarAPI.Source
    }

    private(set) var key: Key?
    private(set) var avatar: Avatar = .unknown

    /// The picture, for the view; nil means "draw initials".
    func image(for userID: String, avatarURL: String?) -> UIImage? {
        guard let source = AccountAvatarAPI.source(avatarURL),
              key == Key(userID: userID, source: source),
              case .image(let image) = avatar else { return nil }
        return image
    }

    @ObservationIgnored private var inFlight: Key?
    /// The seam for `AccountCardTests`. The app's routes each `Source` to the
    /// one place that may fetch it — see `fetchLive`.
    @ObservationIgnored private let fetch: @MainActor (AccountAvatarAPI.Source) async throws -> Data

    init(fetch: @escaping @MainActor (AccountAvatarAPI.Source) async throws -> Data = {
        try await AccountAvatarStore.fetchLive($0)
    }) {
        self.fetch = fetch
    }

    /// Relative → `APIClient` (bearer, refresh, fixture seam). Absolute →
    /// the credential-free session. There is no third branch: `source(_:)`
    /// has already refused everything else.
    nonisolated static func fetchLive(_ source: AccountAvatarAPI.Source) async throws -> Data {
        switch source {
        case .api(let path): try await APIClient.shared.data(for: path)
        case .external(let url): try await AccountAvatarAPI.fetchExternal(url)
        }
    }

    /// Ask once per account per `avatarUrl` value; a transient failure asks
    /// again. A nil or refused value asks NOTHING and forgets what was held.
    func load(for userID: String, avatarURL: String?) async {
        guard let source = AccountAvatarAPI.source(avatarURL) else {
            reset()
            return
        }
        let key = Key(userID: userID, source: source)
        if self.key == key, avatar != .unknown { return }
        if inFlight == key { return }
        if self.key != key {
            self.key = key
            avatar = .unknown
        }
        inFlight = key

        // Captured BEFORE the await: an answer for A that lands after Изход
        // must not become the picture B's Админ opens on.
        let epoch = SessionEpoch.current
        let result: Avatar?
        do {
            let data = try await fetch(source)
            result = AccountAvatarAPI.image(from: data).map(Avatar.image) ?? Avatar.none
        } catch APIClient.APIError.http(404, _, _, _, _) {
            result = Avatar.none
        } catch is AccountAvatarAPI.Unavailable {
            result = Avatar.none
        } catch {
            // Nothing logged here: `APIClient` already logged the status, and
            // a third-party URL is the account's own photo address — personal
            // data, kept out of the log like the email.
            result = nil
        }
        // The same epoch AND still the value on screen: an answer for an
        // `avatarUrl` the refresh has since replaced is not this picture.
        guard SessionEpoch.isCurrent(epoch), self.key == key else { return }
        inFlight = nil
        if let result { avatar = result }
    }

    /// Back to a fresh launch's state — part of `SessionReset`.
    func reset() {
        key = nil
        avatar = .unknown
        inFlight = nil
    }

    #if DEBUG
    /// For `AccountCardTests`, which must seed the SHARED store (the one
    /// `SessionReset` empties) without a fetch.
    func adoptForTesting(userID: String, avatarURL: String, image: UIImage) {
        guard let source = AccountAvatarAPI.source(avatarURL) else { return }
        key = Key(userID: userID, source: source)
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
