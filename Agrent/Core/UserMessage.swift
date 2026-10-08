import Foundation

/// What to show an OPERATOR when something fails, in Bulgarian.
///
/// Not `error.localizedDescription`. Foundation localises to the device
/// locale, and this phone reports en-BG, so an all-Bulgarian screen rendered
/// English. Both offline proofs in Phase 0 produced exactly that:
///
///     Неуспешно зареждане
///     Could not connect to the server.          ← URLError
///
///     Неуспешно зареждане
///     The data couldn't be read because it      ← DecodingError
///     isn't in the correct format.
///
/// The whole argument for the failure path is that the person holding the
/// phone can read it and decide what to do. An English sentence under a
/// Bulgarian heading fails that for the operator this app is actually for,
/// and it fails it precisely when they are in a field with no signal.
///
/// Deliberately NOT a full localisation pass: the app has no string catalogue
/// and every other literal in it is hard-coded Bulgarian. This matches that,
/// rather than pretending to a system that does not exist yet.
enum UserMessage {
    static func text(for error: Error) -> String {
        switch error {
        // The wait is NOT read here. This line is static — it sits on a
        // screen until something replaces it — and a count on a static line
        // goes stale while the person reads it. The surfaces that honour a
        // pause say when, from the pause itself: `rateLimited` below.
        case APIClient.APIError.http(let status, let code, let message, let params, _):
            return httpText(status: status, code: code, message: message, params: params)

        case let api as APIClient.APIError:
            // The rest are written for an operator already — see
            // APIError.errorDescription.
            return api.errorDescription ?? fallback

        case let url as URLError:
            switch url.code {
            case .notConnectedToInternet:
                return "Няма интернет връзка."
            case .timedOut:
                return "Сървърът не отговори навреме."
            case .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return "Няма връзка със сървъра."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "Проблем със защитената връзка."
            default:
                return "Мрежова грешка."
            }

        case is DecodingError:
            // The operator can do nothing about this one, so it says what
            // happened rather than what to try.
            return "Сървърът върна отговор в неочакван формат."

        default:
            return fallback
        }
    }

    private static var fallback: String { "Възникна неочаквана грешка." }

    // MARK: - Server errors

    /// Three sources, in order of how much they know.
    ///
    /// 1. A code this app can name in Bulgarian. Best: written for an
    ///    operator, by us, in their language.
    /// 2. The server's own `message`, when it is a real sentence. The server
    ///    knows things we do not and the wording is often better than a
    ///    category — but it is English, so it is second.
    /// 3. A sentence derived from the STATUS. Says what kind of failure it
    ///    was and nothing it cannot support.
    ///
    /// A 429 skips the second: its prose is boilerplate, and English. See the
    /// status rule inside.
    static func httpText(status: Int, code: String?, message: String?,
                         params: [String: String]? = nil) -> String {
        // A sentence about THIS failure, when the server named what went
        // wrong. Only for codes that have one — see `interpolated`.
        if let code, let built = interpolated(code: code, params: params) { return built }
        if let code, let known = bulgarian[code] { return known }
        // ── A 429 IS SAID BY STATUS, whatever prose came with it ──
        //
        // Measured by running this function on the server's own bodies: the
        // middleware's 429 carries `RATE_LIMITED`, which is in neither table,
        // and a message that IS a sentence — "Too many requests. Retry after
        // 12 seconds." — so the server-message source passed it through.
        // Every 429 from the middleware and the read limiter reached the
        // farmer in English, and so would a thrown `RateLimitedError`, whose
        // "Too many requests" is a sentence too. The status sentence was
        // reachable only for a body with no usable message at all — the auth
        // limiter's bare string, or a proxy's page.
        //
        // A status rule rather than a `RATE_LIMITED` entry, for the reason
        // `isHumanSentence` gives: an entry fixes today's producers, and the
        // next limiter with a new code would be English again. A 429's prose
        // is boilerplate, and its one real fact — the wait — travels in the
        // header, where `APIClient` reads it.
        if status == 429 { return statusText(429) }
        if let message, isHumanSentence(message) { return message }
        return statusText(status)
    }

    // MARK: - The server asked us to wait

    /// For a surface that HONOURS the pause and can say when it ends.
    ///
    /// ≤ 2 minutes it is the status sentence verbatim — «след малко» is what
    /// this app already says, it needs no timer, and it avoids "след 0
    /// секунди", which is what a relative formatter says at the end of a
    /// countdown. Longer, it names the clock time — see `whenRetry`.
    static func rateLimited(remaining: Duration, now: Date = Date()) -> String {
        "Твърде много заявки. Опитайте отново \(whenRetry(remaining: remaining, now: now))."
    }

    /// The outbox banner's line while the queue waits.
    ///
    /// IT NEVER ASKS THE FARMER TO ACT. The queue resumes by itself at the
    /// server's moment, so «опитайте отново» would send a person to press a
    /// button that is not there — the banner hides «Изпрати» for the length
    /// of the pause. And it is not phrased as their fault: the budget the
    /// outbox draws on is the phone's public address, which a carrier shares
    /// with strangers.
    ///
    /// «Изпращането», not «операциите се изпращат», so the line agrees with
    /// one queued operation and with twenty.
    static func outboxRateLimited(remaining: Duration, now: Date = Date()) -> String {
        "Твърде много заявки. Изпращането продължава автоматично "
            + "\(whenRetry(remaining: remaining, now: now))."
    }

    /// The outbox banner's line once the server has said this build is too
    /// old to serve (a 426, agrent-ios#168), in place of «Изпрати».
    ///
    /// UNLIKE the pause's line, it does ask something of the farmer: only a
    /// newer build sends the queue, and installing one is theirs to do. The
    /// rest says what they most need to hear — nothing is lost. The work
    /// stays on the phone exactly as it was, and the updated app sends it.
    ///
    /// «Записите», so it covers a queued spray and a parcel-line mark alike.
    /// «Запазени на телефона» is the app's phrase for work kept to send
    /// (`FieldOperationText.kept`); the web's `bg.json` has no sentence for a
    /// retired build to borrow.
    static let outboxClientTooOld = "Тази версия на приложението е остаряла. "
        + "Записите са запазени на телефона и ще се изпратят след обновяване."

    /// «след малко», or «в 14:33».
    ///
    /// A CLOCK TIME, NOT A COUNT, because nothing re-renders this line every
    /// second and a count would be wrong by the time it was read. A clock time
    /// stays true for as long as it is on screen.
    ///
    /// ROUNDED UP to the minute, so the promise is never earlier than the
    /// gate: a queue that resumes at 14:32:11 is shown as «в 14:33», never as
    /// «в 14:32» with a farmer watching nothing happen for eleven seconds. The
    /// reference date is a UTC minute boundary and every zone in use today is
    /// offset from UTC by whole minutes, so a UTC minute is a local one.
    ///
    /// Computed from `remaining` at render time, so a wall clock changed
    /// during the pause moves only this label — the pause itself runs on
    /// `ContinuousClock` and does not notice.
    private static func whenRetry(remaining: Duration, now: Date) -> String {
        let seconds = remaining / .seconds(1)
        guard seconds > 120 else { return "след малко" }
        let moment = now.addingTimeInterval(seconds).timeIntervalSinceReferenceDate
        let minute = (moment / 60).rounded(.up) * 60
        return "в \(BgDate.time(Date(timeIntervalSinceReferenceDate: minute)))"
    }

    /// Would a person read this as language, or as an identifier?
    ///
    /// This guard exists because of a REAL defect, measured server-side on
    /// 2026-09-22 and not hypothesised: thirty call sites across five modules
    /// were calling `badRequest('INVALID_CROP_TYPE', 'Crop type not found…')`
    /// against a `(message, details)` signature. The code landed in the
    /// MESSAGE field and the sentence was buried in `details`, so `message`
    /// on the wire was a bare `INVALID_CROP_TYPE`. journal.ts was one of the
    /// five, and Дневник is the screen the owner actually uses.
    ///
    /// Those thirty are being fixed. This is not for them.
    ///
    /// It is for the next thirty, whoever writes them: the property worth
    /// holding is not "that bug is fixed" but "an identifier must never reach
    /// an operator", and only one of those two survives someone new adding a
    /// call site next year. A screaming-snake token with no spaces is not a
    /// sentence in any language, so it degrades to the status text rather
    /// than being shown.
    static func isHumanSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Structure, not prose. Caught by this file's own test, which fed it
        // `{"error":{"code":"NOT_FOUND"}}` — a string with no spaces whose
        // lowercase letters made the shouting check below say "language".
        //
        // The check earns its place beyond that contrived input. Rendering a
        // whole body is precisely what this change removes, a 404 here once
        // returned a 102KB HTML page, and `message` is a field someone could
        // one day fill with a serialised object without thinking about this
        // file. Quotes are NOT rejected: `Crop type "wheat" not found` is a
        // real sentence.
        if trimmed.contains(where: { "{}<>".contains($0) }) { return false }

        if trimmed.contains(" ") { return true }
        // One word: an identifier only if it is shouting. A single lowercase
        // or Cyrillic word is unusual but it is still language.
        return trimmed != trimmed.uppercased()
    }

    /// What the STATUS alone supports, and nothing more.
    ///
    /// No status gets "try again" unless trying again could actually work. A
    /// 403 will refuse identically every time, and telling someone to retry
    /// a permission failure wastes their time and their trust in the message.
    static func statusText(_ status: Int) -> String {
        switch status {
        case 400, 422: "Заявката съдържа невалидни данни."
        case 401: "Сесията е изтекла. Влезте отново."
        case 403: "Нямате права за това действие."
        case 404: "Търсеното не беше намерено."
        case 408: "Заявката отне твърде дълго."
        case 413: "Файлът е твърде голям."
        case 429: "Твърде много заявки. Опитайте отново след малко."
        case 500...599: "Проблем със сървъра. Опитайте отново по-късно."
        default: "Възникна грешка при връзката със сървъра."
        }
    }

    /// Server error codes this app can say in Bulgarian.
    ///
    /// Grows by batch as the server adds codes — the server side is
    /// migrating ~530 user-facing English messages onto coded errors, and an
    /// uncoded one still falls through to its English `message`, which is a
    /// real sentence and a legitimate fallback. This map is additive and
    /// nothing breaks by being absent from it.
    ///
    /// NOT a localisation framework. The app has no string catalogue and
    /// every literal in it is hard-coded Bulgarian; this matches that rather
    /// than pretending to a system that does not exist.
    /// Refusals whose sentence needs a value out of `params`.
    ///
    /// Deliberately NOT the same as quoting any parameter the server
    /// sends. `INVALID_TAB_ORDER` carries `params.max` = "12" and this
    /// ignores it, because twelve is a payload bound the farmer is not
    /// subject to — the editor stops at five. The test is whether the
    /// value is the thing that stopped THEM.
    ///
    /// Here it is. `PRODUCT_IS_SAMPLE_ARCHETYPE` names the product that
    /// blocked the completion; without it the sentence describes a
    /// category and leaves a person to work out which of their lines it
    /// means.
    static func interpolated(code: String, params: [String: String]?) -> String? {
        switch code {
        case "FARM_NAME_TOO_LONG":
            // The bound is the server's (`params.max`, agri-saas #1388) — it
            // was a hardcoded 120 here, which would have gone on saying 120
            // whatever the server's limit became. Only a whole number is
            // quoted: anything else is not a length.
            guard let max = params?["max"], Int(max) != nil else { return nil }
            return "Името на стопанството е твърде дълго — до \(max) знака."
        case "PRODUCT_IS_SAMPLE_ARCHETYPE":
            guard let product = params?["product"], !product.isEmpty else {
                return "Операцията използва образцов продукт, а не регистриран. "
                     + "Изберете или създайте реален продукт."
            }
            return "«\(product)» е образцов продукт, а не регистриран. "
                 + "Изберете или създайте реален продукт, преди да отбележите "
                 + "операцията като изпълнена."

        case "INSURANCE_QUOTE_INVALID":
            // `params.reason` names WHICH of the four inputs the server
            // rejected: "area", "sumInsured", "tariff" or "instalments". The
            // app validates all four before sending, so reaching this means
            // the two rules have drifted — and the sentence still has to name
            // the field, because "invalid quote" sends a farmer back to a form
            // with four fields and no idea which one.
            switch params?["reason"] {
            case "area":
                return "Площта не е приета от сървъра. Проверете я и опитайте пак."
            case "sumInsured":
                return "Застрахователната сума не е приета от сървъра. "
                     + "Проверете я и опитайте пак."
            case "instalments":
                return "Броят вноски не е приет от сървъра. Изберете от 1 до 4."
            case "tariff":
                // Not the farmer's input at all. The tariff is the server's,
                // so there is nothing for them to correct.
                return "Тарифата не е налична в момента. Изпратете запитване "
                     + "без изчисление или опитайте по-късно."
            default:
                return "Изчислението не е прието от сървъра. Проверете площта "
                     + "и сумата и опитайте пак."
            }

        case "PESTICIDE_REGULATORY_FIELDS_REQUIRED":
            // The app already blocks this before sending, so reaching it
            // means the two rules have drifted. The sentence still has to
            // work: a farmer must not be shown a refusal only a developer
            // could read.
            guard let missing = params?["missing"], !missing.isEmpty else {
                return "За препарат за РЗ са задължителни рег. № по ЗЗР и "
                     + "карантинен срок."
            }
            return "Липсват задължителни данни за препарат за РЗ: \(missing)."

        default:
            return nil
        }
    }

    static let bulgarian: [String: String] = [
        // The session could not be renewed and the tokens were KEPT, because
        // only a 401 proves a refresh token is dead — see `APIClient`. So the
        // app is still nominally signed in while every request fails, and
        // without this the farmer read «Заявката съдържа невалидни данни.» on
        // whichever screen they happened to open. The owner met it as "the
        // satellite data does not render".
        //
        // THE CAUSE THE FIRST TIME WAS NOT AN EXPIRED SESSION, and the commit
        // that added this said it was. `app.agrent.bg` was intermittently
        // being served by a DIFFERENT APPLICATION: a second product shared the
        // Docker network and declared the same `app` alias, so Docker DNS
        // returned two addresses and Caddy picked one per connection. The
        // other app has no `/api/auth/*` routes, so its catch-all answered 400
        // with no code where agri-saas answers 401 `invalid_grant`.
        //
        // Connection reuse made it sticky, which is why one device failed on
        // every screen while a simulator was fine — and why "his tokens are
        // four days older" fitted the evidence and was wrong. Fixed
        // server-side by pinning the upstream to one container
        // (agri-saas#1143); 40 probes from here now answer identically.
        //
        // Names the fix, because there IS one: «Изход», then sign in again.
        // Says where it is, since the owner moved it out of the menu
        // (2026-10-07): Админ's top row — the account card — opens Профил.
        "TOKEN_REFRESH_FAILED":
            "Сесията не можа да бъде подновена. В «Админ» отворете профила си, "
            + "изберете «Изход» и влезте отново.",

        // ── The insurance quote's own refusals ──
        //
        // Coded rather than prose deliberately, by the server, BECAUSE this
        // app renders the raw envelope: an English sentence from the server
        // would otherwise reach a Bulgarian farmer untranslated. That has
        // happened here before, which is why `httpText` uses `code` as a
        // lookup key and never prints it.
        //
        // `INSURANCE_QUOTE_INVALID` is not here — it carries `params.reason`
        // and is built in `interpolated` above, so it can name the field.
        "INSURANCE_PRODUCT_UNKNOWN":
            "Този вид застраховка вече не се предлага. Изберете друг.",

        // A farmer can do nothing about this one: the key is minted by the
        // app. So it says what happens next rather than asking them to fix
        // something they cannot see.
        "IDEMPOTENCY_KEY_INVALID":
            "Запитването не беше изпратено заради техническа грешка. "
            + "Опитайте пак.",

        // The bottom-row editor. `codedBadRequest` gives this refusal a
        // real identity rather than the shared category code 152 other
        // call sites use, which is what makes it translatable at all.
        //
        // The response also carries `params.max` — currently "12" — and
        // this DOES NOT quote it. iOS caps the bar at five, because that
        // is where the system collapses the rest into "More", so a farmer
        // cannot construct a twelve-item order and telling them the limit
        // is twelve would describe a rule they are not subject to. The
        // number in an error should be the one that stopped them.
        //
        // Which means this refusal is unreachable by normal use: the
        // editor cannot produce duplicates, cannot produce empty ids, and
        // stops at five. If it ever fires it is an iOS defect, so the
        // sentence says the order was not accepted rather than implying
        // the person did something wrong.
        "INVALID_TAB_ORDER": "Подредбата на разделите не беше приета.",

        // Calculator refusals, from `grain.calculator.refusal.*`, VERBATIM.
        //
        // These replace four sentences this app had written itself under a
        // comment claiming they came from the web. They did not. The four
        // were plausible — one was close in meaning — and that is exactly
        // what would have made the false provenance durable: a reader
        // comparing them to the web would have found a discrepancy and had
        // a comment telling them not to bother checking.
        //
        // THREE OF THE FOUR INTERPOLATE, which the invented ones did not,
        // so they were not merely differently worded — they were missing
        // information. Substitution happens in `RefusalText`, not here,
        // because `{commodity}` needs translating before it goes in.
        "NO_MARKET_PRICE":
            "Няма налична пазарна цена за {commodity}.",
        "MIXED_COST_CURRENCY":
            "Разходите са записани в повече от една валута; смесването им в нетната стойност би изкривило общата сума.",
        "RENT_CURRENCY_UNRECORDED":
            "Договорът за аренда не записва валута за рентата, затова тя не може да се съчетае с активи, оценени по пазарна цена, без да се измисли такава.",
        "COST_PRICE_CURRENCY_MISMATCH":
            "Разходите са в {costCurrency}, а пазарната цена е в {priceCurrency}; не се извършва конвертиране на валута.",

        // Authorisation. The code is deliberately CATEGORY-LEVEL:
        // `requirePermission` never echoes the permission key to the
        // client, because the key names a capability and telling an
        // unauthorised caller which one they lack is an enumeration aid.
        // So this maps to a general sentence and nothing finer is
        // expected — that is the design, not a gap.
        //
        // A denial also writes an AUTHZ_DENIED audit row, so a refusal is
        // visible to the farm's owner. Worth knowing before anything here
        // grows a retry.
        "FORBIDDEN": "Нямате права за това действие.",

        // Every zod refusal, app-wide: `toApiErrorResponse` answers a
        // `ZodError` with this code and the English "Invalid request payload",
        // which IS a sentence, so `isHumanSentence` passed it straight to the
        // farmer. Met first on the farm-profile editor, whose client-side
        // checks mirror the route's schema — reaching this there means the two
        // have drifted, and the farmer still needs a sentence they can read.
        "VALIDATION_ERROR": "Сървърът не прие данните. Проверете полетата и опитайте отново.",

        // The terms gate (`middleware.ts`): every farm and person route
        // refuses a caller who has not accepted the terms of use. Not a
        // permission — saying "you lack the rights" would send them to the
        // farm's owner for something only they can do. Coded by the server
        // since agri-saas #1405.
        "TERMS_ACCEPTANCE_REQUIRED":
            "Трябва да приемете условията за ползване. Отворете уеб приложението, "
            + "приемете ги и опитайте отново.",

        // Creating a farm (`POST /api/me/farms`, agri-saas#1362) — codes
        // rather than prose BY DESIGN, so the words are this app's. The two
        // ЕИК lines are the web wizard's own (`farmWizard.eikLooksLikeEgn`,
        // `eikInvalid`): an ЕГН typed by mistake is said to be one, never
        // called "invalid".
        "FARM_NAME_REQUIRED": "Въведете име на стопанството.",
        // The limit itself comes from `params.max` (`interpolated`); this is
        // for a refusal that does not carry it.
        "FARM_NAME_TOO_LONG": "Името на стопанството е твърде дълго.",
        "FARM_NAME_NOT_SLUGGABLE":
            "Името трябва да съдържа поне една буква или цифра — не само знаци.",
        "FARM_SLUG_UNAVAILABLE":
            "Не успяхме да създадем адрес за това име. Опитайте с малко по-различно име.",
        "EIK_LOOKS_LIKE_EGN": "Това прилича на ЕГН — не го въвеждайте тук.",
        "EIK_INVALID": "Това не е валиден ЕИК. Проверете цифрите.",
        "ACCOUNT_HAS_NO_EMAIL":
            "Профилът Ви няма имейл адрес, а без него не може да се създаде стопанство.",
        "INVALID_FARM_PAYLOAD":
            "Сървърът не прие данните за стопанството. Проверете полетата и опитайте отново.",

        // The farm-profile PUT refuses ANY body that carries `eik`, even
        // unchanged or null (agri-saas#1352, P3.9): the ЕИК is written only by
        // Agrent staff verifying the farm's identity. This client never sends
        // the key (`FarmProfileText.writable`), so reaching this means an older
        // build or payload did — and the farmer needs to know the rest was not
        // saved either, and where the ЕИК is changed instead.
        "FARM_PROFILE_EIK_NOT_EDITABLE":
            "ЕИК не може да се променя оттук и профилът не е записан. "
            + "ЕИК се променя само след проверка от екипа на Agrent.",

        // ── Exchange messaging (agrent-ios#114) ──
        //
        // The server's sentences are English and the web has no Bulgarian
        // for any of these — it shows one generic line per action — so they
        // are written here. Three rules they follow:
        //
        // SIDE-NEUTRAL where the side is unknown. The server's `seller` means
        // the LISTING'S OWNER, who is the one buying on a BUY listing, and no
        // messaging payload says which. So «собственикът на обявата», never
        // «продавачът», in a refusal that can meet either.
        //
        // PERSON or FARM, whichever the server checks — and since agri-saas
        // #1323 (#1298) that differs by rule, so each sentence names the one
        // its code means. «Вие» is the PERSON: the conversation's audience,
        // retract (`MESSAGE_NOT_SENDER` compares the sender) and the read
        // pointer are per person. The FARM stays where the check is still a
        // farm's: your own listing (`THREAD_OWN_LISTING` compares tenants, so
        // a colleague's listing counts). The block is a PERSON's since
        // agri-saas #1397, and `THREAD_BLOCKED` speaks to the person it
        // refuses. No sentence says «блокирахте това стопанство»; see
        // `MessagingPolicy.blockedNotice`.
        //
        // NOTHING SAYS «В ТОЗИ РАЗГОВОР» about a limit. The send budget is
        // the whole farm's, sixty a minute across every thread and device,
        // and a 429 is said by status anyway — see `httpText`.
        //
        // Not the found-or-not-visible distinction: `THREAD_NOT_FOUND` is
        // what anyone outside the conversation's audience gets, a colleague
        // at a party farm included (a 404, not a 403, so it cannot leak that
        // a colleague is talking to someone). So it neither claims the
        // conversation was deleted nor names a colleague. The conversation
        // screen does not show this sentence — a 404 there is its own state,
        // `ConversationAvailability` — but the listing's «Съобщение до …»
        // can still meet it.
        "THREAD_NOT_FOUND": "Разговорът не е намерен или не е достъпен за Вас.",
        // Defensive server-side and unreachable while its row-level security
        // holds; worded so that it is true if it ever fires.
        "THREAD_NOT_A_PARTY": "Вашето стопанство не е участник в разговора.",
        "BLOCK_SELLER_ONLY": "Само собственикът на обявата може да блокира или отблокира.",
        "LISTING_NOT_FOUND": "Обявата не беше намерена.",
        "THREAD_OWN_LISTING": "Не можете да започнете разговор по обява на Вашето стопанство.",
        // Said to whoever the server refuses: the person blocked, opening a
        // conversation on any listing of that farm or writing in theirs. A
        // colleague of theirs is not refused elsewhere; if the server refuses
        // one in the blocked conversation, «от Вас» overstates it slightly,
        // and the notice under the conversation says the exact scope.
        "THREAD_BLOCKED": "Собственикът на обявата не приема съобщения от Вас.",
        // Reached only when the server's sanitiser strips a draft the app
        // thought had text — `<ivan@abv.bg>` is a tag to it — because the
        // composer does not send a blank one.
        "MESSAGE_EMPTY": "Съобщението е празно след проверката на сървъра. Напишете текст.",
        // No number: the limit is 4000 UTF-16 units, which is not a count a
        // farmer can check (an emoji is two to four), and the composer shows
        // its own counter near it.
        "MESSAGE_TOO_LONG": "Съобщението е твърде дълго. Съкратете го и опитайте отново.",
        "MESSAGE_NOT_FOUND": "Съобщението не беше намерено.",
        "MESSAGE_NOT_SENDER": "Можете да премахвате само съобщения, които сте изпратили Вие.",

        // ── Marking a field operation's parcel lines (agrent-ios#138) ──
        //
        // The 403 is the common failure here, not the offline case: the
        // route lets the ASSIGNED operator mark without general write
        // permission, and nobody else — so a colleague's job refuses. The
        // screen hides the buttons from whoever the role says cannot mark,
        // but the role can be the OLDEST membership's until the farm list
        // has said (`CurrentUser.role`), and the assignment can change under
        // an open screen, so the refusal is still met. The web's own sentence, `ag.map.fieldOp.markForbidden`,
        // VERBATIM — it says who CAN do it, which «Нямате права» does not.
        "OPERATION_NOT_ASSIGNED_TO_YOU":
            "Можете да отбелязвате само задания, възложени на вас. Потърсете "
            + "отговорника за това задание.",
        // `ag.map.fieldOp.notFound`, verbatim. Also what a task that is not
        // a field operation answers — the route's 404 covers both.
        "FIELD_OPERATION_NOT_FOUND": "Земеделската операция не е намерена.",
        // The web has no sentence of its own for this one (its panel shows
        // the generic «не беше запазено»). A line removed from the job while
        // the screen was open, or a mark replayed after it was.
        "OPERATION_PARCEL_NOT_FOUND": "Този ред вече не е част от операцията.",

        // Batch 1.
        "CROP_PLAN_NOT_READY": "Планът за културите не е готов.",
        "FILE_EMPTY": "Файлът е празен.",
        "FILE_TOO_LARGE": "Файлът е твърде голям.",
        "FILE_TYPE_NOT_ALLOWED": "Този тип файл не се приема.",
        "FILE_VALIDATION_ERROR": "Файлът не премина проверката.",
        "INVALID_ASSET": "Активът не е намерен или принадлежи на друго стопанство.",
        "INVALID_CROP_TYPE": "Културата не е намерена или принадлежи на друго стопанство.",
        "INVALID_EQUIPMENT": "Техниката не е намерена или принадлежи на друго стопанство.",
        "INVALID_FARM_TASK_TYPE": "Този вид задача не съществува.",
        "INVALID_FILE": "Файлът е невалиден.",
        "INVALID_LINK": "Връзката е невалидна.",
        "INVALID_LOCATION": "Локацията не е намерена или принадлежи на друго стопанство.",
        "INVALID_PARCEL": "Парцелът не е намерен или принадлежи на друго стопанство.",
        "INVALID_PLANTING": "Засаждането не е намерено или принадлежи на друго стопанство.",
        "INVALID_SEASON": "Сезонът не е намерен или принадлежи на друго стопанство.",
        "INVALID_TASK": "Задачата не е намерена или принадлежи на друго стопанство.",
        "INVALID_VARIETY": "Сортът не е намерен или принадлежи на друго стопанство.",
        "PARCEL_LOCATION_MISMATCH": "Парцелът не принадлежи на тази локация.",
    ]
}
