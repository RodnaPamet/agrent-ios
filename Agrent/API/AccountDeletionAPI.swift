import Foundation

/// Deleting one's own account, in the app (agrent-ios#281; agri-saas #1597
/// P5.6, #1598 P5.7).
///
/// ── Why it is here at all ──
///
/// App Store guideline 5.1.1(v): an app in which an account can be created
/// must let the person delete it in the app. A link to the web is a
/// rejection, so this ships in the same release as the server side (owner,
/// recorded on agri-saas #1598).
///
/// ── What a request does ──
///
/// `POST` starts a grace period and FREEZES the account: every live session
/// is revoked at once, this phone's included, so the caller goes signed-out
/// locally and never retries. Asking twice does not restart the clock —
/// `alreadyRequested` says so and the original `erasesAt` stands. The date is
/// shown as the server sent it and never computed here: two places deriving
/// one deadline is two places to get it wrong.
///
/// At the end of the grace period the account is pseudonymised, not erased
/// whole — the privacy notice says what survives, and `DeleteAccountView`
/// says no more than it does.
///
/// ── Recovery is explicit (owner, 2026-10-11) ──
///
/// Signing in does not cancel. A person whose deletion is pending signs in
/// and sees only the recovery screen, whose «Възстанови профила» is `cancel`.
/// Revoked sessions are not restored by it; the ability to sign in is.
///
/// ── The export is not here ──
///
/// `GET /api/account/export` stays on the web (owner, 2026-10-11).
///
/// Never fired from development, CI or the screenshot harness: the owner
/// makes the first real request.
enum AccountDeletionAPI {
    static let path = "/api/account/deletion"

    /// `AccountDeletionRequested`.
    struct Requested: Decodable, Equatable, Sendable {
        /// A request was already outstanding; `erasesAt` is ITS date.
        let alreadyRequested: Bool
        /// When the erasure runs. Nullable in the spec, so a sentence
        /// without a date exists for it.
        let erasesAt: Date?

        private enum CodingKeys: String, CodingKey { case alreadyRequested, erasesAt }

        init(alreadyRequested: Bool, erasesAt: Date?) {
            self.alreadyRequested = alreadyRequested
            self.erasesAt = erasesAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alreadyRequested = try c.decodeIfPresent(Bool.self, forKey: .alreadyRequested) ?? false
            // Through `BgDate`, the one instant parser: with or without
            // fractional seconds. A date this build cannot read costs the
            // date, never the answer that the request was recorded.
            erasesAt = (try? c.decodeIfPresent(String.self, forKey: .erasesAt)).flatMap { $0 }
                .flatMap(BgDate.parseInstant)
        }
    }

    /// `AccountDeletionCancelled`. `wasRequested: false` means nothing was
    /// pending — success, not an error.
    struct Cancelled: Decodable, Equatable, Sendable {
        let wasRequested: Bool
    }

    /// Ask for the account to be deleted. No body. Not retried by anything
    /// here: if it landed, this phone's session is already gone.
    static func request() async throws -> Requested {
        let data = try await APIClient.shared.postReturningData(path, body: EmptyBody(), idempotencyKey: nil)
        return try await APIClient.shared.decode(data, as: Requested.self)
    }

    /// Cancel a pending deletion — the recovery screen's «Възстанови профила».
    static func cancel() async throws -> Cancelled {
        let data = try await APIClient.shared.deleteReturningData(path)
        return try await APIClient.shared.decode(data, as: Cancelled.self)
    }

    private struct EmptyBody: Encodable {}
}
