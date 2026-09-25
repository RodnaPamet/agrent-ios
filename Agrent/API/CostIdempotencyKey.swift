import CryptoKit
import Foundation

/// The `Idempotency-Key` for `POST /grain/costs`.
///
/// One key per DRAFT: minted from a nonce that lives as long as the sheet,
/// re-minted the moment the draft's content changes. Owner's decision,
/// 2026-09-25.
///
/// ── Why both halves are needed ──
///
/// The route dedupes on the key (`clientMutationId`, unique index), so the
/// key IS the identity of the write. Get that identity wrong in either
/// direction and the farm's books are wrong, silently, with a 200 on screen:
///
///   - **Too stable** — reuse a key after the operator corrects the amount
///     and the server returns the ORIGINAL row. The correction is dropped
///     and the books keep the wrong figure. So the content must be in the
///     key.
///   - **Too fresh** — the farm buys 200 L of diesel twice on the same day,
///     same supplier, no notes. Two identical drafts. A pure content hash
///     gives both the same key, so the second LEGITIMATE row is deduped away
///     and never written. So something per-presentation must be in the key
///     too.
///
/// Hence nonce + content. The nonce scopes the hash to ONE sheet: a second
/// sheet with identical content mints a different key and writes, while an
/// edit inside one sheet mints a different key and lands as its own row.
///
/// ── Why a hash of the content and not `.onChange` re-minting ──
///
/// Re-minting a fresh UUID on every edit looks equivalent and is not. The
/// operator types `12,50`, corrects to `12,5`, corrects back to `12,50` —
/// that is a third UUID, so the identical figures that may ALREADY have
/// landed on the first attempt are no longer deduped against it. A content
/// hash is stable under edit-and-revert: the same content in the same sheet
/// is always the same key, however many keystrokes it took to get back
/// there.
///
/// ── Why the key material is the draft's own `Encodable` output ──
///
/// Not a hand-listed set of fields. Going through `CreateCostEntry`'s own
/// `encode(to:)` means a field added later is in the key the day it is
/// added. A hand-built key string drifts: add `vatRate`, forget the key, and
/// editing that field silently reuses the key, which is the exact
/// books-corruption failure above.
///
/// The encoder is LOCAL and synchronous on purpose. `APIClient.encodeBody`
/// is actor-isolated and would make this `async` for no gain: the key only
/// has to be a FUNCTION OF CONTENT, not byte-identical to what goes on the
/// wire. Two drafts differ here exactly when they differ there, which is all
/// the invariant needs.
///
/// ── `.sortedKeys` IS LOAD-BEARING. DO NOT REMOVE IT. ──
///
/// `CreateCostEntry.encode(to:)` is hand-written with a fixed `CodingKeys`
/// order, and that is NOT enough to make its JSON canonical. A keyed
/// container goes into an unordered dictionary, and `JSONEncoder` emits it in
/// that dictionary's iteration order — which varies between calls in ONE
/// process, because Swift seeds each dictionary's hashing separately.
/// Measured while writing this, two encodings of the same value:
///
///     {"amount":1250.75,"currency":"BGN"}
///     {"currency":"BGN","amount":1250.75}
///
/// Same content, different bytes, different digest. Without `.sortedKeys`
/// this whole mechanism inverts: pressing Запази twice with identical figures
/// would usually mint two DIFFERENT keys, the server would dedupe nothing,
/// and the retry protection would exist only in the comments. `.sortedKeys`
/// fixes one deterministic order, so the digest depends on the content alone.
///
/// Nothing else in this repo noticed, because the assertions on this encoding
/// in `CostEntryTests` are `json.contains(…)` — order-insensitive by
/// construction. `CostIdempotencyTests` mints the same draft many times over
/// specifically to pin this down; that test is what caught it.
///
/// ── Why the result is UUID-SHAPED, and this is not cosmetic ──
///
/// Lowercase 8-4-4-4-12 hex, from the first 16 bytes of the digest.
///
/// The server's accepted shape for this header value is recorded NOWHERE —
/// not in the generated OpenAPI spec, not in this repo. Every
/// `Idempotency-Key` this app has ever sent is a UUID: `APIClient.post`'s
/// `UUID().uuidString` default, `JournalAPI`, `ParcelOperationSheet`,
/// `OutboxStore`, `ItemCatalogue`, `FarmRiskModels`. So a UUID is the one
/// shape KNOWN to be accepted in production.
///
/// If there is a `z.string().uuid()` or a length cap on that header, a
/// 64-character hex digest turns every cost save into a 400 — on a money
/// screen, in Bulgarian, for a farmer standing in a field. And `Tests/` has
/// no URLProtocol seam, so nothing here could catch it: the first evidence
/// would be an operator unable to record a cost. A UUID-shaped key keeps
/// the format byte-for-byte the shape that already works while staying a
/// deterministic function of the draft. 128 bits of SHA-256 is far more than
/// this needs — the comparison is against other keys from one sheet on one
/// phone, not against a global namespace.
///
/// The version and variant bits are set to v4 for the same reason, not for
/// RFC conformance for its own sake: a validator strict enough to check the
/// shape may be strict enough to check those nibbles, and every key that has
/// ever worked against this server had them. Six bits of a space that does
/// not need them is the cheapest possible insurance.
enum CostIdempotencyKey {

    /// The key for `draft` within the sheet presentation identified by
    /// `nonce`.
    ///
    /// Pure: same nonce and same content give the same key, always, with no
    /// stored state anywhere. That is what makes the invariant testable
    /// without a network seam — and the invariant is the whole feature.
    ///
    /// The single exception is the encode-failure branch below, which is
    /// unreachable and says so. Naming it here rather than letting the word
    /// "always" stand unqualified: an absolute in a doc comment is the thing
    /// this repo keeps discovering to be false.
    static func mint(nonce: String, draft: CreateCostEntry) -> String {
        // A local, synchronous encoder — see the header on why not
        // `APIClient.encodeBody`. `.sortedKeys` is REQUIRED, not tidiness:
        // without it the same draft encodes to different byte orders and
        // mints different keys. The header has the measurement.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        guard let body = try? encoder.encode(draft) else {
            // Unreachable: `CreateCostEntry.encode(to:)` writes strings, a
            // `Decimal` and nothing else, and none of those throw. Kept
            // total anyway, and the fallback leans the SAFE way: a fresh
            // value is deduped against nothing, which is exactly the
            // behaviour this screen had before today. Never a stale key —
            // a stale key is the one outcome that loses a correction, and
            // deriving one from the nonce alone would produce exactly that.
            //
            // LOWERCASED, because `UUID().uuidString` is UPPERCASE and this
            // function's whole contract with the server is a lowercase
            // 8-4-4-4-12 value. The unreachable branch was the one place that
            // broke the shape the reachable branch is careful to produce, and
            // the tests assert the shape only on the reachable one.
            return UUID().uuidString.lowercased()
        }

        // LENGTH-PREFIXED, not merely NUL-separated.
        //
        // The separator argument used to read "a UUID string cannot contain a
        // NUL, so no nonce-and-content pair can be confused with another" —
        // which is true of the only caller and NOT of the signature. `mint`
        // takes an arbitrary `String`, and the tests say so out loud: "any
        // fixed string does — `mint` treats it as opaque". An argument that
        // holds because of who happens to call it is the same shape as a guard
        // that cannot fire: correct today, quietly wrong the day somebody
        // passes something else.
        //
        // The byte count makes the framing unambiguous whatever the nonce
        // contains, so nothing downstream depends on a claim about its
        // alphabet.
        var material = Data()
        var length = UInt32(Data(nonce.utf8).count).littleEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(Data(nonce.utf8))
        material.append(body)

        return Self.uuidString(from: SHA256.hash(data: material))
    }

    /// The first 16 bytes of a digest, spelled as a lowercase UUID.
    private static func uuidString(from digest: SHA256.Digest) -> String {
        var bytes = Array(digest.prefix(16))

        // Version 4, variant RFC 4122 — see the header. This is the only
        // place the digest is altered, and it is six bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)
                       ..< hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return groups.joined(separator: "-")
    }
}
