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
        case APIClient.APIError.http(let status, let code, let message, let params):
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
    static func httpText(status: Int, code: String?, message: String?,
                         params: [String: String]? = nil) -> String {
        // A sentence about THIS failure, when the server named what went
        // wrong. Only for codes that have one — see `interpolated`.
        if let code, let built = interpolated(code: code, params: params) { return built }
        if let code, let known = bulgarian[code] { return known }
        if let message, isHumanSentence(message) { return message }
        return statusText(status)
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
        // Names the fix, because there IS one and it is two taps: «Изход» in
        // the menu, then sign in again.
        "TOKEN_REFRESH_FAILED":
            "Сесията не можа да бъде подновена. Излезте от менюто и влезте "
            + "отново.",

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
