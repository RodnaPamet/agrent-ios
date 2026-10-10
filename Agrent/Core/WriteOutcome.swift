import Foundation

/// Whether a write that failed in transport certainly wrote nothing (#265).
///
/// A `URLError` is not one outcome. Most say the ANSWER was lost, and the
/// write may have landed before it was: a timeout, a dropped connection, a
/// TLS failure. A few say the connection was never made, so the request
/// never left the phone and the server has nothing to have written: no
/// signal, cellular data off for the app or while roaming, a name that did
/// not resolve, a host that refused the connect.
///
/// Telling a farmer with no signal that a cost «may be saved» sends them to
/// the list to look for something that cannot be there, and «Общи» locks the
/// whole sheet for it.
///
/// ── An allow-list, so a code nobody has looked at stays unknown ──
///
/// The two mistakes are not equal. Wrongly saying «not saved» invites an
/// edited re-entry that books twice; wrongly saying «may be saved» only asks
/// the farmer to look.
///
/// ── What still holds if iOS is wrong about one of these ──
///
/// Were one of these ever reported after the body had left (a network that
/// went away mid-request), «Запази» on the unchanged form sends the same
/// `Idempotency-Key` (`CostIdempotencyKey`), and the server answers with the
/// row it already has rather than writing a second. Only an edited retry
/// would book twice.
///
/// `APIClient.send`'s 401 replay changes none of this: a first attempt the
/// server answered 401 wrote nothing either, so the failure of the refresh or
/// of the second attempt is the only one that speaks for the write.
enum WriteOutcome {
    static func neverSent(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .cannotFindHost, .dnsLookupFailed,
             .cannotConnectToHost:
            true
        default:
            false
        }
    }
}
