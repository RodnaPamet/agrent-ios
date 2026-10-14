import XCTest
@testable import Agrent

/// What an operator reads when the server refuses.
///
/// Before this, the whole JSON body went on screen inside one Bulgarian
/// sentence:
///
///     Грешка от сървъра (404): {"error":{"code":"NOT_FOUND",
///     "message":"Access review not found"}}
///
/// Braces, quotes and an English sentence, on a screen whose only actionable
/// question is whether to try again — with the server's own `code` sitting
/// inside that string, already decodable.
final class ServerErrorEnvelopeTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    func testCodeAndMessageAreReadOffAnyStatus() {
        let e = envelope(#"{"error":{"code":"INVALID_PARCEL","message":"Parcel not found"}}"#)
        XCTAssertEqual(e?.code, "INVALID_PARCEL")
        XCTAssertEqual(e?.message, "Parcel not found")
    }

    /// The 409 path has parsed this shape against real responses since the
    /// optimistic-locking work. Generalising it must not break it.
    func testConflictDetailsStillDecode() {
        let e = envelope(#"""
        {"error":{"code":"STALE_DATA","message":"Changed","details":{"currentVersion":7,"expectedVersion":5}}}
        """#)
        XCTAssertEqual(e?.details?.currentVersion, 7)
        XCTAssertEqual(e?.details?.expectedVersion, 5)
    }

    /// A 404 once returned Next.js's 102,151-byte HTML error page. An error
    /// path that can itself fail is how that became a blank screen, so this
    /// returns nil rather than throwing — and, unlike the 300-character cap
    /// it replaces, no fragment of that HTML can reach a view at all.
    func testHTMLErrorPageYieldsNothingRatherThanAFragment() {
        XCTAssertNil(envelope("<!DOCTYPE html><html><body>500</body></html>"))
        XCTAssertNil(envelope(""))
        XCTAssertNil(envelope("null"))
    }

    func testWellFormedJSONWithoutAnErrorKeyIsNotAnError() {
        XCTAssertNil(envelope(#"{"rows":[]}"#))
    }
}

final class UserMessageHTTPTests: XCTestCase {

    /// A code this app knows beats everything else: written for an operator,
    /// by us, in their language.
    /// Over a Bulgarian message too, which would otherwise be shown.
    func testAKnownCodeWinsOverTheServersMessage() {
        XCTAssertEqual(
            UserMessage.httpText(
                status: 400, code: "INVALID_PARCEL",
                message: "Парцелът не е намерен."
            ),
            "Парцелът не е намерен или принадлежи на друго стопанство."
        )
    }

    /// An unmapped code falls through to the server's sentence when it is
    /// Bulgarian — agri-saas resolves `message` from the person's language
    /// (#1677) — and to the status sentence when it is English. Never English
    /// on screen (owner, 2026-10-13); ~500 refusals are still English prose.
    func testAnUnknownCodeFallsBackToTheServersBulgarianOnly() {
        XCTAssertEqual(
            UserMessage.httpText(status: 404, code: "LEASE_NOT_FOUND", message: "Договорът не е намерен."),
            "Договорът не е намерен."
        )
        XCTAssertEqual(
            UserMessage.httpText(status: 404, code: "NOT_FOUND", message: "Listing not found"),
            "Търсеното не беше намерено.", "an English 404 reached the farmer"
        )
        XCTAssertEqual(
            UserMessage.httpText(status: 400, code: "SOME_FUTURE_CODE", message: "Delta must be non-zero."),
            "Заявката съдържа невалидни данни.", "an English 400 reached the farmer"
        )
    }

    /// The majority of the letters decides, because each language quotes
    /// the other: a Bulgarian product named in English prose is English, a
    /// Latin brand named in Bulgarian prose is Bulgarian.
    func testBulgarianIsTheMajorityOfTheLetters() {
        XCTAssertTrue(UserMessage.isBulgarianSentence("Продуктът \"Karate Zeon\" не е намерен."))
        XCTAssertFalse(UserMessage.isBulgarianSentence("Product \"Карате Зеон\" not found"))
        XCTAssertFalse(UserMessage.isBulgarianSentence("Listing not found"))
        // Still a sentence first: an identifier is no language at all.
        XCTAssertFalse(UserMessage.isBulgarianSentence("НЕ_Е_НАМЕРЕН"))
        XCTAssertFalse(UserMessage.isBulgarianSentence("{\"грешка\": 1}"))
        XCTAssertTrue(UserMessage.isBulgarianSentence("Не е намерен."), "positive control")
        // Quoted names count for neither side: what is quoted is a name, in
        // either alphabet, and says nothing about the sentence around it.
        XCTAssertFalse(UserMessage.isBulgarianSentence(#"Parcel "Нивата при Долна Митрополия" is archived"#),
                       "a long Bulgarian name carried English onto the screen")
        XCTAssertTrue(UserMessage.isBulgarianSentence("Няма цена за „Roundup Max“."),
                      "a Latin brand cost a Bulgarian sentence")
        XCTAssertTrue(UserMessage.isBulgarianSentence("Стопанството «Agro Invest Holding Bulgaria EOOD» вече съществува."))
        XCTAssertFalse(UserMessage.isBulgarianSentence("„Само име“"), "a quote alone is no sentence of either")
    }

    /// The guard, and the defect behind it. Thirty call sites called
    /// `badRequest('INVALID_CROP_TYPE', 'Crop type not found…')` against a
    /// `(message, details)` signature, so a bare code travelled in the
    /// message field. Those are being fixed; this must hold for the NEXT
    /// thirty, which is a different claim and the one worth testing.
    func testABareCodeInTheMessageFieldNeverReachesTheOperator() {
        let text = UserMessage.httpText(
            status: 400, code: "BAD_REQUEST", message: "INVALID_CROP_TYPE"
        )
        XCTAssertEqual(text, "Заявката съдържа невалидни данни.")
        XCTAssertFalse(text.contains("INVALID_CROP_TYPE"))
        XCTAssertFalse(text.contains("_"))
    }

    func testIdentifierDetection() {
        XCTAssertFalse(UserMessage.isHumanSentence("INVALID_CROP_TYPE"))
        XCTAssertFalse(UserMessage.isHumanSentence("NOT_FOUND"))
        XCTAssertFalse(UserMessage.isHumanSentence("   "))
        XCTAssertFalse(UserMessage.isHumanSentence(""))
        // Real sentences, including a one-word one and a Cyrillic one.
        XCTAssertTrue(UserMessage.isHumanSentence("Crop type not found."))
        XCTAssertTrue(UserMessage.isHumanSentence("unauthorized"))
        XCTAssertTrue(UserMessage.isHumanSentence("Неуспешно"))
    }

    /// Structure is not prose, and the shouting check alone does not say so:
    /// `{"error":{"code":"NOT_FOUND"}}` has no spaces, and its lowercase
    /// letters make it differ from its own uppercasing, so it read as
    /// language. Found by this suite before the code shipped.
    func testSerialisedStructureIsNotASentence() {
        XCTAssertFalse(UserMessage.isHumanSentence(#"{"error":{"code":"NOT_FOUND"}}"#))
        XCTAssertFalse(UserMessage.isHumanSentence("<html><body>500</body></html>"))
        // Quotes alone are fine — this is a real sentence.
        XCTAssertTrue(UserMessage.isHumanSentence(#"Crop type "wheat" not found"#))
    }

    func testWithNoCodeAndNoBodyTheStatusCarriesIt() {
        XCTAssertEqual(
            UserMessage.httpText(status: 503, code: nil, message: nil),
            "Проблем със сървъра. Опитайте отново по-късно."
        )
        XCTAssertEqual(
            UserMessage.httpText(status: 403, code: nil, message: nil),
            "Нямате права за това действие."
        )
    }

    /// A 403 refuses identically every time. Telling someone to retry a
    /// permission failure wastes their time and their trust in the message,
    /// so only the statuses where retrying can actually work say so.
    func testOnlyRetryableStatusesSuggestRetrying() {
        for status in [400, 401, 403, 404, 413] {
            let text = UserMessage.statusText(status)
            XCTAssertFalse(
                text.lowercased().contains("опитайте"),
                "status \(status) suggests a retry that cannot succeed: \(text)"
            )
        }
        for status in [429, 500, 503] {
            XCTAssertTrue(
                UserMessage.statusText(status).lowercased().contains("опитайте"),
                "status \(status) is retryable and should say so"
            )
        }
    }

    /// No raw JSON, no braces, no English identifier — whatever the server
    /// sends. The old behaviour failed every one of these.
    func testNothingMachineReadableSurvivesToTheScreen() {
        let bodies: [(Int, String?, String?)] = [
            (404, "NOT_FOUND", #"{"error":{"code":"NOT_FOUND"}}"#),
            (400, "BAD_REQUEST", "INVALID_SEASON"),
            (500, nil, nil),
            (422, nil, "FILE_TOO_LARGE"),
        ]
        for (status, code, message) in bodies {
            let text = UserMessage.httpText(status: status, code: code, message: message)
            XCTAssertFalse(text.contains("{"), text)
            XCTAssertFalse(text.contains("\""), text)
            XCTAssertFalse(text.contains("_"), text)
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// Every mapped string must be Bulgarian prose, not a pasted identifier
    /// and not English left in by accident. Cheap to assert across the whole
    /// table, and it is the kind of thing that rots one entry at a time as
    /// batches land.
    func testEveryMappedMessageIsBulgarianProse() {
        XCTAssertFalse(UserMessage.bulgarian.isEmpty)
        for (code, text) in UserMessage.bulgarian {
            XCTAssertFalse(text.contains("_"), "\(code) looks like an identifier")
            XCTAssertTrue(text.hasSuffix("."), "\(code) is not a sentence")
            XCTAssertTrue(
                text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x400 },
                "\(code) has no Cyrillic in it"
            )
        }
    }

    /// agri-saas's coded-but-UNDOCUMENTED refusals that can reach the paths
    /// this app builds: backend 1 crossed its baseline with
    /// `Tests/Contract/app-routes.txt` on 2026-10-11 and found these 49.
    /// Each has its own sentence here, not the generic status line. Run
    /// through `httpText` itself, not looked up in the table: some are built
    /// in `interpolated` or matched elsewhere. With a Bulgarian placeholder
    /// and the status line ruled out — an English message falls to the
    /// status line by itself now, sentence of ours or not.
    func testEveryUndocumentedCodeReachableHereIsSaidInBulgarian() {
        let english = "Title is required for this entry."
        let placeholder = "Сървърът каза нещо."
        XCTAssertTrue(UserMessage.isBulgarianSentence(placeholder), "precondition")
        XCTAssertTrue(UserMessage.isHumanSentence(english), "precondition")
        let measured = [
            "ACCOUNT_HAS_NO_EMAIL", "API_KEY_FAMILY_NOT_ENABLED", "API_KEY_WRONG_SURFACE",
            // Coded since agri-saas #1645; `FORBIDDEN` with the token as `message` before.
            "OPERATOR_SCOPE", "API_KEY_NOT_PERSON_SCOPED", "AI_BUDGET_REQUIRES_VERIFIED_FARM",
            "BLOCK_SELLER_ONLY", "CROP_SEASON_YEAR_INVALID", "CROP_TYPE_INVALID", "DOSE_UNIT_NOT_FOUND",
            "FARM_NAME_NOT_SLUGGABLE", "FARM_NAME_REQUIRED", "FARM_SLUG_UNAVAILABLE",
            "FIELD_OPERATION_NOT_FOUND", "FILE_TOO_LARGE", "FILE_TYPE_NOT_ALLOWED", "IDEMPOTENCY_KEY_INVALID",
            "IF_MATCH_EMPTY", "IF_MATCH_MALFORMED", "IF_MATCH_WEAK_TAG", "INSURANCE_PRODUCT_UNKNOWN",
            "INSURANCE_QUOTE_INVALID", "INVALID_EQUIPMENT", "INVALID_FARM_PAYLOAD", "INVALID_FILE",
            "INVALID_LIMIT", "INVALID_LOCATION", "INVALID_PLANTING", "INVALID_REVIEW_ACTION",
            "INVALID_TAB_ORDER", "ITEM_NAME_ALREADY_EXISTS", "JOURNAL_ENTRY_NOT_DELETED",
            "JOURNAL_ENTRY_NOT_FOUND", "JOURNAL_ENTRY_NOT_SOFT_DELETED", "JOURNAL_FILE_LINK_NOT_FOUND",
            "JOURNAL_TITLE_REQUIRED", "LISTING_NOT_FOUND", "LOCATION_NOT_FOUND", "MESSAGE_NOT_FOUND",
            "NOTES_TOO_LONG", "NOT_A_FIELD_OPERATION_TASK", "OPERATION_NOT_ASSIGNED_TO_YOU",
            "OPERATION_PARCEL_NOT_FOUND", "PARCELS_NOT_IN_LOCATION", "PRODUCT_IS_SAMPLE_ARCHETYPE",
            "TASK_NOT_AWAITING_REVIEW", "THREAD_NOT_A_PARTY", "THREAD_NOT_FOUND", "WATER_RATE_UNIT_NOT_FOUND",
            "WATER_RATE_UNIT_REQUIRED", "WEED_ENTRIES_TOO_MANY", "WEED_NAME_TOO_LONG",
        ]
        XCTAssertEqual(measured.count, 52)
        for code in measured {
            let text = UserMessage.httpText(status: 400, code: code, message: placeholder)
            XCTAssertNotEqual(text, placeholder, "\(code) has no sentence here")
            XCTAssertNotEqual(text, UserMessage.statusText(400), "\(code) has no sentence here")
            XCTAssertNotEqual(UserMessage.httpText(status: 400, code: code, message: english), english,
                              "\(code) reaches the screen in English")
        }
    }

    /// The error path itself must never be the thing that fails. This is the
    /// route a blank screen took once already.
    func testEveryStatusProducesSomethingReadable() {
        for status in [100, 204, 301, 400, 418, 451, 500, 599, 999] {
            XCTAssertFalse(UserMessage.statusText(status).isEmpty, "status \(status)")
        }
    }
}

/// The auth routes answer in a different envelope shape from everything
/// else, and the diagnostic added to chase the sign-out bug is what found
/// it: the refresh failure logged `(401 no code)` when the server had sent a
/// code, in the other shape. A diagnostic that under-reports is worse than
/// none, because it is believed.
final class AuthEnvelopeShapeTests: XCTestCase {

    private func envelope(_ json: String) -> APIClient.ErrorEnvelope.Err? {
        APIClient.envelope(from: Data(json.utf8))
    }

    /// The shape every refresh failure actually uses.
    func testABareStringErrorIsReadAsACode() {
        XCTAssertEqual(envelope(#"{"error":"invalid_grant"}"#)?.code, "invalid_grant")
    }

    /// And the object form still works — this must not be a swap.
    func testTheObjectFormStillDecodes() {
        let e = envelope(#"{"error":{"code":"INVALID_PARCEL","message":"Parcel not found"}}"#)
        XCTAssertEqual(e?.code, "INVALID_PARCEL")
        XCTAssertEqual(e?.message, "Parcel not found")
    }

    /// A bare code is an identifier, so it must not be rendered at an
    /// operator — `invalid_grant` is lowercase and would pass the
    /// shouting check, so the code path matters: it is mapped or it falls
    /// back to the status, never printed raw as prose.
    func testTheAuthCodeDoesNotReachTheScreenAsProse() {
        let text = UserMessage.httpText(status: 401, code: "invalid_grant", message: nil)
        XCTAssertFalse(text.contains("invalid_grant"))
        XCTAssertEqual(text, "Сесията е изтекла. Влезте отново.")
    }
}

/// The farm's subscription, refused in words that say which (agrent-ios#241).
/// Both are 403s; neither is a missing right, and neither may send anyone to
/// pay outside the app (App Store guideline 3.1.1) — so both are statements.
final class SubscriptionRefusalTests: XCTestCase {

    func testAPastDueFarmIsToldWhyNotThatItLacksRights() {
        let text = UserMessage.httpText(status: 403, code: "PAST_DUE_RESTRICTED",
                                        message: "Your subscription payment is past due.")
        XCTAssertEqual(text, "Тази функция е спряна, защото плащането за абонамента на стопанството не е преминало.")
    }

    /// The middleware's 403s reach every route, and each message is English
    /// that `httpText` would have shown verbatim. The messages are the
    /// server's own (`src/middleware.ts`), so the positive control is that
    /// they ARE sentences.
    func testTheMiddlewaresRefusalsAreSaidInBulgarian() {
        let refusals = [
            ("ADMIN_REQUIRED", "Admin access required"),
            ("MFA_REQUIRED", "MFA verification required"),
            ("CSRF_BLOCKED", "Cross-site admin requests are not allowed"),
        ]
        for (code, english) in refusals {
            XCTAssertTrue(UserMessage.isHumanSentence(english), "precondition: \(code)")
            let text = UserMessage.httpText(status: 403, code: code, message: english)
            XCTAssertNotEqual(text, english, code)
            XCTAssertEqual(text, UserMessage.bulgarian[code], code)
        }
    }

    /// A plan limit is said by its CODE, whatever its message says. The prose
    /// prefix that told it apart before agri-saas #1679 is no longer read
    /// (agrent-ios#307): the server dropped it, and the wording of a message
    /// never decides what happened.
    func testAPlanLimitIsSaidByItsCodeAndNeverByProse() {
        XCTAssertEqual(UserMessage.httpText(status: 403, code: "PLAN_LIMIT_EXCEEDED",
                                            message: "FREE plan allows 1 location(s); tenant currently has 1."),
                       "Достигнат е лимитът на абонаментния план на стопанството.")
        // The control: the retired prefix under FORBIDDEN is a FORBIDDEN.
        XCTAssertEqual(UserMessage.httpText(status: 403, code: "FORBIDDEN",
                                            message: "plan_limit_exceeded: Your plan allows 1 location."),
                       "Нямате права за това действие.")
    }

    /// The plan's refusals as codes (agri-saas #1679, agrent-ios #286), as
    /// they arrive: still leading their `message` with the old English token
    /// for one release, and next in the reader's language (agri-saas #1677).
    /// The code decides either way, so neither change on the server's side
    /// can turn a limit into «Нямате права».
    /// A role that cannot change records is named in Bulgarian, with the
    /// one person who can change it — and never as the server's English or
    /// the role's wire name.
    func testAWriteRefusedForTheRoleNamesTheRole() {
        let english = "You do not have permission to modify records in this context."
        let reader = UserMessage.httpText(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: english,
                                          params: ["role": "READER"])
        XCTAssertTrue(reader.contains("«Читател»"), reader)
        XCTAssertTrue(reader.contains("администратор"), reader)
        XCTAssertTrue(UserMessage.httpText(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: english,
                                           params: ["role": "MECHANISATOR"]).contains("«Механизатор»"))
        XCTAssertTrue(UserMessage.httpText(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: english,
                                           params: ["role": "AUDITOR"]).contains("«Одитор»"))

        let generic = UserMessage.httpText(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: english)
        XCTAssertNotEqual(generic, UserMessage.statusText(403), "the code has its own sentence")
        for unknown in ["SUPERVISOR", "UNKNOWN", ""] {
            let text = UserMessage.httpText(status: 403, code: "WRITE_FORBIDDEN_FOR_ROLE", message: english,
                                            params: ["role": unknown])
            XCTAssertEqual(text, generic, "an unknown role \(unknown) is not quoted")
        }
        for text in [reader, generic] {
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), text)
            XCTAssertFalse(text.contains("READER") || text.contains("permission"), text)
        }
    }

    func testThePlansRefusalsAreSaidByCode() {
        let refusals: [(code: String, legacy: String, params: [String: String])] = [
            ("PLAN_LIMIT_EXCEEDED", "plan_limit_exceeded: FREE plan allows 1 location(s); tenant currently has 1.",
             ["plan": "FREE", "resource": "location", "limit": "1", "current": "1"]),
            ("AI_BUDGET_EXCEEDED", "ai_budget_exceeded: FREE plan allows 1000 AI tokens per month.",
             ["plan": "FREE", "limit": "1000", "used": "1000"]),
            ("AI_TIER_NOT_ALLOWED", "ai_tier_not_allowed: FREE plan allows up to fast.",
             ["plan": "FREE", "tier": "deep", "ceiling": "fast"]),
            ("MODULE_DISABLED", "module_disabled: the trends module is disabled.", ["module": "trends"]),
            // What a #1688 server sends when the plan leaves a module out. Not
            // "tenant": that one names an administrator, which is right for it
            // and is tested on its own below.
            ("MODULE_DISABLED", "module_disabled: TRENDS", ["module": "TRENDS", "reason": "plan"]),
            ("BILLING_UNAVAILABLE", "billing_unavailable: plan changes are not available.", ["mode": "self_hosted"]),
        ]
        var said = Set<String>()
        for refusal in refusals {
            let english = UserMessage.httpText(status: 403, code: refusal.code,
                                               message: refusal.legacy, params: refusal.params)
            let translated = UserMessage.httpText(status: 403, code: refusal.code,
                                                  message: "Достигнат е лимит.", params: refusal.params)
            XCTAssertEqual(english, translated, "\(refusal.code) depends on its message")
            XCTAssertNotEqual(english, "Нямате права за това действие.", "\(refusal.code) reads as a missing right")
            XCTAssertNotEqual(english, refusal.legacy, "\(refusal.code) reaches the screen in English")
            XCTAssertFalse(english.localizedCaseInsensitiveContains("опитайте"), "\(refusal.code) offers a retry that cannot work")
            said.insert(english)
        }
        XCTAssertEqual(said.count, refusals.count, "two conditions with different remedies share a sentence")
        XCTAssertEqual(UserMessage.httpText(status: 403, code: "PLAN_LIMIT_EXCEEDED", message: nil),
                       UserMessage.planLimitReached, "the coded limit and the legacy prefix say different things")
        // Without `reason`, none of them sends the farmer to an administrator:
        // a module is also refused when the PLAN leaves it out, where no
        // administrator can help.
        XCTAssertFalse(said.contains { $0.localizedCaseInsensitiveContains("администратор") })
    }

    /// `MODULE_DISABLED` names the administrator only when `params.reason`
    /// says the farm switched the module off (agri-saas #1688). The plan
    /// half, an absent reason and one this app does not know all name
    /// nobody, whatever the message says.
    func testOnlyAFarmsOwnSwitchSendsTheFarmerToAnAdministrator() {
        func said(_ reason: String?) -> String {
            var params = ["module": "GRAIN"]
            params["reason"] = reason
            return UserMessage.httpText(status: 403, code: "MODULE_DISABLED",
                                        message: "module_disabled: GRAIN", params: params)
        }
        XCTAssertTrue(said("tenant").contains("Администратор на стопанството"))
        XCTAssertEqual(said(nil), UserMessage.bulgarian["MODULE_DISABLED"],
                       "an absent reason is not the neutral sentence")
        for reason in ["plan", nil, "seat"] {
            XCTAssertFalse(said(reason).localizedCaseInsensitiveContains("администратор"),
                           "reason \(reason ?? "absent") sends the farmer to someone who cannot help")
        }
        XCTAssertTrue(said("plan").contains("абонаментния план"))
        // Positive control: the three are three different sentences.
        XCTAssertEqual(Set([said("tenant"), said("plan"), said(nil)]).count, 3)
        XCTAssertEqual(said(nil), said("seat"), "an unknown reason is not the neutral sentence")
    }
}
