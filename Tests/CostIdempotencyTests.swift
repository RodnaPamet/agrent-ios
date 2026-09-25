import XCTest
@testable import Agrent

/// The `Idempotency-Key` for `POST /grain/costs`.
///
/// ── What is actually at stake, and why it is tested HERE ──
///
/// The route dedupes on this value (`clientMutationId`, unique index), so the
/// key IS the identity of the write. Two failures follow from getting it
/// wrong, and BOTH are silent — a 200 on screen and wrong figures in a farm's
/// books:
///
///   - a key that survives an edit → the operator's correction is answered
///     with the ORIGINAL row and dropped;
///   - a key that is only the content → the farm's second identical diesel
///     purchase of the day is deduped away and never written.
///
/// Neither shows up in a view test and neither shows up in a decode test.
/// There is no URLProtocol seam in `Tests/`, so the outgoing header cannot be
/// observed at all from here. What CAN be pinned down completely is the pure
/// function that mints the value — `CostIdempotencyKey.mint` takes a nonce
/// and a draft and returns a string with no stored state anywhere — and the
/// invariant lives entirely inside it. So these tests exercise that function
/// and nothing about `NewCostView`'s rendering.
///
/// The shape assertions are not cosmetic either: the server's accepted shape
/// for that header value is recorded NOWHERE — not in the generated spec, not
/// in this repo — and every key this app has ever sent successfully was a
/// UUID. If there is a `z.string().uuid()` or a length cap behind it, a
/// 64-character hex digest turns every cost save into a 400 on a money
/// screen, and the first evidence would be a farmer unable to record a cost.
/// A test is the only thing standing between that and a refactor.
final class CostIdempotencyTests: XCTestCase {

    /// One sheet presentation's nonce. Any fixed string does — `mint` treats
    /// it as opaque bytes — and a UUID is what the view actually supplies.
    private let nonce = "6C4E0E84-8F9C-4F8E-9B0A-1D2C3E4F5A6B"
    private let otherNonce = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"

    private func draft(
        category: CostCategory = .fuel,
        amount: Decimal = Decimal(string: "1250.75")!,
        currency: String = "BGN",
        incurredOn: String = "2026-09-25",
        supplier: String? = nil,
        description: String? = nil
    ) -> CreateCostEntry {
        CreateCostEntry(
            category: category, amount: amount, currency: currency,
            incurredOn: incurredOn, supplier: supplier, description: description
        )
    }

    private func key(
        _ entry: CreateCostEntry, nonce: String? = nil
    ) -> String {
        CostIdempotencyKey.mint(nonce: nonce ?? self.nonce, draft: entry)
    }

    // MARK: - Stable under retry

    /// The point of the whole mechanism: pressing Запази again with the same
    /// figures in the same sheet must produce the SAME key, so the server
    /// recognises the replay instead of writing a second cost.
    ///
    /// ── THIS TEST HAS ALREADY EARNED ITS KEEP ──
    ///
    /// It is a loop, not two calls, and that is why it caught the real bug on
    /// the first run. `JSONEncoder` puts a keyed container into an UNORDERED
    /// dictionary and emits it in that dictionary's iteration order, which
    /// Swift seeds per instance — so the first version of `mint`, which
    /// trusted `CreateCostEntry.encode(to:)`'s fixed `CodingKeys` order to
    /// make the JSON canonical, produced these from one value:
    ///
    ///     {"amount":1250.75,"currency":"BGN"}
    ///     {"currency":"BGN","amount":1250.75}
    ///
    /// Different bytes, different digest, different key — so two presses of
    /// Запази with identical figures would have minted different keys and the
    /// server would have deduped NOTHING. The fix is `.sortedKeys`; this loop
    /// is what stops anyone removing it as decoration. Two calls could easily
    /// have agreed by luck and shipped the inversion of the feature.
    ///
    /// The full draft is included because more fields mean more orderings,
    /// and the minimal one because omitted optionals mean fewer.
    func testTheSameDraftInTheSameSheetAlwaysMintsTheSameKey() {
        let full = draft(supplier: "Петрол АД", description: "цистерна, 200 л")

        for entry in [draft(), full] {
            let minted = Set((0..<200).map { _ in key(entry) })
            XCTAssertEqual(minted.count, 1, "\(minted)")
        }

        // And an equal draft built separately, not the same instance — the
        // key is a function of VALUES, not of object identity.
        XCTAssertEqual(key(draft()), key(draft()))
    }

    // MARK: - Every field is in the key

    /// A changed figure must mint a NEW key, or the server answers the
    /// correction with the row it is correcting.
    ///
    /// All six fields, one assertion each, because the failure this guards
    /// against is a field being LEFT OUT of the key: a hand-built key string
    /// drifts the day someone adds `vatRate` and forgets it, and then editing
    /// that field silently reuses the key. `mint` goes through the draft's
    /// own `Encodable` output precisely so a new field is in the key the day
    /// it is added — this test is what says so.
    func testChangingAnyFieldMintsADifferentKey() {
        let original = key(draft())

        XCTAssertNotEqual(original, key(draft(category: .seed)))
        XCTAssertNotEqual(original, key(draft(amount: Decimal(string: "1250.76")!)))
        XCTAssertNotEqual(original, key(draft(currency: "EUR")))
        XCTAssertNotEqual(original, key(draft(incurredOn: "2026-09-24")))
        XCTAssertNotEqual(original, key(draft(supplier: "Петрол АД")))
        XCTAssertNotEqual(original, key(draft(description: "цистерна")))

        // Six distinct edits, six distinct keys — and distinct from each
        // other too, not merely from the original.
        let all = Set([
            original,
            key(draft(category: .seed)),
            key(draft(amount: Decimal(string: "1250.76")!)),
            key(draft(currency: "EUR")),
            key(draft(incurredOn: "2026-09-24")),
            key(draft(supplier: "Петрол АД")),
            key(draft(description: "цистерна")),
        ])
        XCTAssertEqual(all.count, 7, "\(all)")
    }

    /// An omitted optional and a present empty one are different bytes on the
    /// wire (`encodeIfPresent` drops the first, sends the second), so they
    /// are different keys. The form maps empty to nil before it ever gets
    /// here, so this is not a user-reachable case — it is a check that the
    /// key follows the ENCODING rather than a hand-listed idea of the fields.
    func testAnOmittedOptionalDiffersFromAPresentEmptyOne() {
        XCTAssertNotEqual(key(draft(supplier: nil)), key(draft(supplier: "")))
    }

    // MARK: - Why a content hash, and not a re-mint on every edit

    /// The case that rules out `.onChange { nonce = UUID() }`.
    ///
    /// The operator types 12,50, corrects to 15,00, corrects back to 12,50.
    /// A re-minted UUID would now be a THIRD value, so the first attempt's
    /// figures — which may already have reached the server — are no longer
    /// deduped against. A content hash returns to the original key, because
    /// the content has returned to the original content.
    func testEditAndRevertReturnsTheOriginalKey() {
        let first = key(draft(amount: Decimal(string: "12.50")!))
        let corrected = key(draft(amount: Decimal(string: "15.00")!))
        let reverted = key(draft(amount: Decimal(string: "12.50")!))

        XCTAssertNotEqual(first, corrected)
        XCTAssertEqual(first, reverted)
    }

    /// The same edit-and-revert, on a string field and through the whole
    /// draft rather than one parameter — supplier typed, cleared, typed
    /// again. Same invariant, different field, because "revert" must not be
    /// a property of `amount` alone.
    func testEditAndRevertOnATextFieldReturnsTheOriginalKey() {
        let typed = key(draft(supplier: "Петрол АД"))
        XCTAssertNotEqual(typed, key(draft(supplier: nil)))
        XCTAssertEqual(typed, key(draft(supplier: "Петрол АД")))
    }

    /// 12,50 and 12,5 are the same amount, so they are the same key.
    ///
    /// Worth pinning: the operator deleting a trailing zero has not changed
    /// the figure, `Decimal` encodes both as `12.5`, and a key that moved
    /// here would stop deduping a retry over a keystroke that means nothing.
    /// It is also the reason the key hashes the ENCODED draft rather than the
    /// text in the field.
    func testTwoSpellingsOfOneAmountAreOneKey() {
        XCTAssertEqual(
            key(draft(amount: Decimal(string: "12.50")!)),
            key(draft(amount: Decimal(string: "12.5")!))
        )
    }

    // MARK: - Why the nonce, and not a pure content hash

    /// The farm buys 200 L of diesel twice on the same day: same category,
    /// same amount, same supplier, no notes. Two LEGITIMATE rows.
    ///
    /// A pure content hash gives both the same key and the server dedupes the
    /// second away — a cost the farm really paid, absent from its books, with
    /// a success on screen. The nonce scopes the hash to one sheet, so the
    /// second sheet writes.
    func testADifferentSheetWithIdenticalContentMintsADifferentKey() {
        let identical = draft(amount: 200, supplier: "Петрол АД")
        XCTAssertNotEqual(key(identical), key(identical, nonce: otherNonce))
    }

    // MARK: - The wire shape

    /// Lowercase 8-4-4-4-12 hex, and nothing else.
    ///
    /// Not cosmetic — see the header. Every `Idempotency-Key` this app has
    /// ever sent is a UUID, the server's accepted shape for the header is
    /// recorded nowhere, and a 64-character digest would be discovered by a
    /// farmer getting a 400 on a money screen. The regex is deliberately
    /// anchored and deliberately lowercase.
    func testTheKeyIsUuidShaped() {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        for entry in [
            draft(),
            draft(category: .payroll, amount: 1, currency: "EUR",
                  incurredOn: "2026-01-01", supplier: "АД", description: "тест"),
            draft(amount: CreateCostEntry.maxAmount),
        ] {
            let minted = key(entry)
            XCTAssertEqual(minted.count, 36, minted)
            XCTAssertNotNil(
                minted.range(of: pattern, options: .regularExpression), minted)
        }
    }

    /// Foundation agrees it is a UUID, and the version and variant nibbles
    /// are the ones a real `UUID()` would carry.
    ///
    /// A validator strict enough to check the shape may be strict enough to
    /// check those nibbles — `z.string().uuid()` does, in some versions — and
    /// every key that has worked against this server had them. Six bits of a
    /// 128-bit space, pinned so nobody removes them as pointless.
    func testTheKeyParsesAsAUuidWithTheUsualVersionAndVariant() {
        let minted = key(draft())
        XCTAssertNotNil(UUID(uuidString: minted), minted)

        let characters = Array(minted)
        // "xxxxxxxx-xxxx-Mxxx-Nxxx-xxxxxxxxxxxx"
        XCTAssertEqual(characters[14], "4", minted)
        XCTAssertTrue("89ab".contains(characters[19]), minted)
    }
}
