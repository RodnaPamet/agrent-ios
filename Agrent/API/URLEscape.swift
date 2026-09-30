import Foundation

/// The ONE place a value becomes part of a request URL (agrent-ios#122).
///
/// ── The contract ──
///
/// `APIClient.url(for:)` takes both halves of its argument VERBATIM: the
/// path through `percentEncodedPath`, the query through `percentEncodedQuery`.
/// So a builder encodes each value it interpolates exactly once, here, and
/// nothing downstream encodes again.
///
/// ── Why it is not the other way round ──
///
/// The issue offered two fixes: builders stop escaping and `url(for:)`
/// encodes, or builders escape and `url(for:)` stops. Only the second can be
/// right. `url(for:)` sees a whole string and cannot tell a `/` that
/// separates segments from a `/` inside an id, nor a `?` that starts the
/// query from one inside an id — only the builder knows which characters are
/// data. That is also why the query was already verbatim; the path being the
/// exception is what #122 was. Measured before this change:
///
///     analysisPath("par_holes")  → wire …/parcels/par%255Fholes/analysis
///     parcelsPath("a/b?c")       → wire …/locations/a/b   query "c/parcels"
///
/// The first is a 404 for any id with `_` or `-` (escaped, then escaped
/// again by `URLComponents.path`'s setter); the second is a request moved to
/// a different route. Production ids are cuids and hit neither — but "the
/// server happens to mint safe ids" was the only thing standing between
/// these builders and the wrong route.
enum URLEscape {

    /// RFC 3986 "unreserved", spelled as ASCII on purpose.
    ///
    /// NOT `CharacterSet.alphanumerics`, which is what every call site used
    /// before. That set is Unicode-wide (`ж` and `²` are members); it only
    /// behaved because `addingPercentEncoding` happens to encode every
    /// non-ASCII byte regardless. And it escaped `-._~`, which is what turned
    /// `par_holes` into `par%5Fholes` in the first place. Unreserved
    /// characters mean the same encoded or not (RFC 3986 §2.3), so a server
    /// sees no difference in a query value; in a path it is the difference
    /// between one encoding and two.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// A value as ONE path segment: `/`, `?`, `#`, `%` and everything else
    /// outside `unreserved` is escaped, so an id can neither add a segment,
    /// start a query, nor be read as an escape it did not contain.
    static func segment(_ value: String) -> String {
        // Cannot fail for a Swift `String`: it is always valid Unicode, so
        // there is always a UTF-8 encoding to escape. The fallback exists only
        // because the API is optional; it is never reached.
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// A value inside a query string. `&`, `=`, `+` are escaped: a cursor is
    /// base64 and may carry `=` or `+`, and a search term is whatever the
    /// operator typed.
    static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Whether `s` is a well-formed percent-encoded string over `allowed`:
    /// every character either in `allowed` (ASCII only) or a `%` followed by
    /// two hex digits.
    ///
    /// `url(for:)` checks this BEFORE handing a string to `URLComponents`,
    /// because `percentEncodedPath` and `percentEncodedQuery` do not fail
    /// softly — measured, both `fatalError` ("Attempting to set
    /// percentEncodedPath with invalid characters") on a raw space, a raw `ж`
    /// or a `%zz`. A builder bug has to be a thrown `badURL`, not a crash.
    /// `urlPathAllowed` and `urlQueryAllowed` were each probed against every
    /// printable ASCII character: none traps.
    static func isPercentEncoded(_ s: String, allowed: CharacterSet) -> Bool {
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "%" {
                guard i + 2 < scalars.count,
                      scalars[i + 1].properties.isASCIIHexDigit,
                      scalars[i + 2].properties.isASCIIHexDigit
                else { return false }
                i += 3
                continue
            }
            guard c.isASCII, allowed.contains(c) else { return false }
            i += 1
        }
        return true
    }
}
