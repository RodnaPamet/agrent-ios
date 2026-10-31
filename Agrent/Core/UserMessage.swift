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
    /// 2. The server's own `message`, when it is a sentence IN BULGARIAN
    ///    (`isBulgarianSentence`). agri-saas resolves it from the person's
    ///    own language since #1677, so for a code this build does not know it
    ///    is the most specific Bulgarian there is.
    /// 3. A sentence derived from the STATUS. Says what kind of failure it
    ///    was and nothing it cannot support.
    ///
    /// ── NEVER ENGLISH (owner, 2026-10-13) ──
    ///
    /// The second source used to be any real sentence, English included:
    /// "the server knows things we do not". It also meant ~500 uncoded
    /// refusals reached a Bulgarian farmer as "Listing not found". The owner
    /// chose Bulgarian only: an English `message` now falls to the status
    /// sentence. agri-saas is translating its refusals a surface at a time
    /// (#1677, still open); each one it translates appears here with no app
    /// update, and until then the status sentence is what is said.
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
        if let message, isBulgarianSentence(message) { return message }
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

    /// A sentence a Bulgarian farmer can read: `isHumanSentence`, with more
    /// Cyrillic letters than Latin ones in its PROSE (owner, 2026-10-13:
    /// Bulgarian only).
    ///
    /// The two languages quote each other, and what is quoted is a name, in
    /// either alphabet, that says nothing about the sentence around it:
    /// `Parcel "Нивата при Долна Митрополия" is archived` is English, and
    /// «Няма цена за „Roundup Max“.» is Bulgarian. So quoted text — "…",
    /// „…“, “…”, «…» — is left out of the count. Not single quotes: English
    /// apostrophes would pair up across a sentence.
    static func isBulgarianSentence(_ text: String) -> Bool {
        guard isHumanSentence(text) else { return false }
        let prose = text.replacingOccurrences(
            of: #""[^"]*"|„[^“”"]*[“”"]|“[^”]*”|«[^»]*»"#, with: " ", options: .regularExpression)
        var cyrillic = 0
        var latin = 0
        for scalar in prose.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        return cyrillic > latin
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
        // A coded 409 that is not a stale edit (#240): something with that
        // name or key already exists. Re-reading will not change it.
        case 409: "Това вече съществува на сървъра."
        case 413: "Файлът е твърде голям."
        case 429: "Твърде много заявки. Опитайте отново след малко."
        case 500...599: "Проблем със сървъра. Опитайте отново по-късно."
        default: "Възникна грешка при връзката със сървъра."
        }
    }

    /// A statement and nothing more, for the reason `PAST_DUE_RESTRICTED`'s
    /// is (agrent-ios#241).
    static let planLimitReached = "Достигнат е лимитът на абонаментния план на стопанството."

    /// Server error codes this app can say in Bulgarian.
    ///
    /// Grows by batch as the server adds codes — the server side is
    /// migrating ~530 user-facing English messages onto coded errors and
    /// translating them (#1677). A code absent here falls to the server's
    /// `message` when that is Bulgarian, and to the status sentence when it
    /// is English (`httpText`). This map is additive and nothing breaks by
    /// being absent from it.
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
        case "MODULE_DISABLED":
            // `params.reason` says which half of AVAILABLE refused (agri-saas
            // #1688): the remedies differ, and only "tenant" has someone who
            // can lift it. Anything else, absent included, is the table's
            // sentence, which names nobody and is true of both.
            switch params?["reason"] {
            case "tenant":
                // Indefinite: a farm can have several administrators, and the
                // reader may be one. The switch is the web's (admin/modules);
                // this app has none, so the sentence says where it is.
                return "Тази част от приложението е изключена за стопанството. "
                     + "Администратор на стопанството може да я включи от уеб приложението."
            case "plan":
                return "Тази част от приложението не е включена в абонаментния план на стопанството."
            default:
                return nil
            }
        case "FARM_NAME_TOO_LONG":
            // The bound is the server's (`params.max`, agri-saas #1388) — it
            // was a hardcoded 120 here, which would have gone on saying 120
            // whatever the server's limit became. Only a whole number is
            // quoted: anything else is not a length.
            guard let max = params?["max"], Int(max) != nil else { return nil }
            return "Името на стопанството е твърде дълго — до \(max) знака."
        case "NOTES_TOO_LONG", "WEED_NAME_TOO_LONG", "WEED_ENTRIES_TOO_MANY":
            // A parcel's history, with the bound in the sentence (agri-saas
            // #1973, #1976), read from `params.max` as `FARM_NAME_TOO_LONG`
            // is. With no whole number the table's plain sentence stands, so
            // a server that sends none still reads correctly.
            guard let max = params?["max"], Int(max) != nil else { return nil }
            return switch code {
            case "NOTES_TOO_LONG": "Бележките са твърде дълги — до \(max) знака."
            case "WEED_NAME_TOO_LONG": "Името на плевела е твърде дълго — до \(max) знака."
            default: "Твърде много плевели в едно наблюдение — до \(max)."
            }
        case "CROP_SEASON_YEAR_INVALID":
            // The range is computed on the server (its upper end is next
            // year but one), so `params` is the only place it can come from.
            guard let min = params?["min"], let max = params?["max"],
                  Int(min) != nil, Int(max) != nil else { return nil }
            return "Годината на реколтата трябва да е между \(min) и \(max)."
        case "WRITE_FORBIDDEN_FOR_ROLE", "ADMIN_FORBIDDEN_FOR_ROLE", "AUDIT_FORBIDDEN_FOR_ROLE":
            // The person's role in THIS farm may not do this — change records
            // (agri-saas #1767), or an operation that needs an administrator
            // or an auditor (#1779) — and `params.role` says which role. Only
            // an administrator of the farm can give another role, so unlike
            // `MODULE_DISABLED` without its reason, this one may send them
            // there. The role is named in Bulgarian or not at all: a role this
            // build does not know falls to the table's sentence, which names
            // none. The server's own Bulgarian for #1779 quotes the wire name
            // («(EDITOR)»), which is why these are said here.
            guard let raw = params?["role"], let role = MembershipRole(rawValue: raw), role != .unknown else {
                return nil
            }
            // «това действие» for the two from #1779: the route itself was
            // open to the role (the Edge's ADMIN_REQUIRED says that one), so
            // the screen they are on is theirs and only this operation is not.
            let refused = switch code {
            case "ADMIN_FORBIDDEN_FOR_ROLE": "извършите това действие — то е само за администратор"
            case "AUDIT_FORBIDDEN_FOR_ROLE": "извършите това действие — то е за одитор или администратор"
            default: "променяте записи"
            }
            return "С роля «\(role.label)» в това стопанство не можете да \(refused). "
                 + "Друга роля може да Ви даде администратор на стопанството."
        case "REFERENCE_NOT_IN_TENANT":
            // One code for anything chosen that is not this farm's (agri-saas
            // #1740), and `params.reference` says which list held it. On
            // «Ново мероприятие» that is the parcels: one removed on the web
            // after the phone read them. Any other list is the table's
            // sentence, which names none.
            return params?["reference"] == "parcels"
                ? "Някой от избраните парцели вече не е в това стопанство. Проверете избора и опитайте отново."
                : nil
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
            // The spray sheet asks for both whenever a typed product is new
            // (#237), so reaching this means its match and the server's have
            // drifted — or a record queued before the catalogue arrived. The
            // sentence still has to work: `params.missing` holds WIRE names,
            // and «pppRegistrationNo» quoted into a Bulgarian sentence is a
            // refusal only a developer could read. Named in Bulgarian, or
            // not named at all.
            let generic = "За нов препарат са задължителни рег. № по ЗЗР и карантинен срок."
            guard let missing = params?["missing"], !missing.isEmpty else { return generic }
            let named = missing.split(separator: ",").map {
                regulatoryFieldNames[$0.trimmingCharacters(in: .whitespaces)]
            }
            guard !named.isEmpty, named.allSatisfy({ $0 != nil }) else { return generic }
            return "Липсва за нов препарат: \(named.compactMap { $0 }.joined(separator: " и "))."

        // ── The superuser's day of prices (#258, agri-saas #1587) ──
        //
        // Each refuses the WHOLE day. `params.commodity` is a slug or the
        // spelling sent, so it is named through `CommodityName`, never quoted
        // raw. The form sends one field per row the server listed, so the
        // first three mean the two lists drifted; the fourth is real.
        //
        // A row the sentence can't name is «една от стоките», not «една от
        // културите»: the day's prices include diesel and fertiliser, so the
        // owner's word for the whole set is «стока» (agri-saas #2051).
        case "DUPLICATE_COMMODITY":
            return commodityNamed(params, "Цената на „%@“ е въведена два пъти за един ден.",
                                  otherwise: "Една от цените е въведена два пъти за един ден.")
        case "UNKNOWN_COMMODITY":
            return commodityNamed(params, "Сървърът не разпознава „%@“.",
                                  otherwise: "Сървърът не разпознава една от стоките.")
        case "COMMODITY_NOT_OVERRIDABLE":
            return commodityNamed(params, "За „%@“ не се въвежда цена от тук.",
                                  otherwise: "За една от стоките не се въвежда цена от тук.")
        case "OVERRIDE_DENOMINATION_CHANGED":
            // `stored` and `expected` are «EUR EUR/t»: currency, then unit.
            // The unit says it all, and is what differs.
            let unit = { (key: String) in params?[key]?.split(separator: " ").last.map(String.init) }
            let name = params?["commodity"].flatMap { CommodityName.canonical($0) }
            guard let name, let stored = unit("stored"), let expected = unit("expected") else {
                return "Една от цените е въведена в друга мярка. Изчистете я, преди да въведете нова."
            }
            return "Цената на „\(name)“ е въведена в \(stored), а вече се въвежда в \(expected). "
                 + "Изчистете я, преди да въведете нова."

        // ── Parcel-boundary upload (agri-saas #1633) ──
        //
        // The phone refuses an oversized or unsupported file BEFORE sending
        // (`SpatialImportRefusal`), against the same caps and extensions, so
        // meeting either here means the two rules drifted. The server's
        // values are used then: they are what refused the file.
        case "SPATIAL_UPLOAD_TOO_LARGE":
            guard let size = megabytes(params, "size"),
                  let limit = megabytes(params, "limit") else {
                return "Файлът е твърде голям. Опростете го или го разделете на части."
            }
            return SpatialImportRefusal.tooLargeText(
                megabytes: size, limit: limit,
                format: params?["format"].flatMap(SpatialImportFormat.init(rawValue:)))
        case "UNSUPPORTED_FILE_TYPE":
            // `allowed` is the extensions, space-separated.
            let allowed = params?["allowed"]?.split(separator: " ").joined(separator: ", ") ?? ""
            return allowed.isEmpty
                ? "Този тип файл не се приема."
                : "Този тип файл не се приема. Приемат се: \(allowed)."

        default:
            return nil
        }
    }

    /// A figure in megabytes, from either of the two forms the server has
    /// sent it in.
    ///
    /// - `<name>Bytes`, a whole number of bytes (agri-saas #1447's follow-up).
    /// - `<name>`, as #1633 shipped it: «7.2 MB», formatted for English with
    ///   a point and always one decimal («5.0 MB»). Read back so it can be
    ///   said again with a comma. Megabytes only: a figure in another unit is
    ///   not quoted as one.
    private static func megabytes(_ params: [String: String]?, _ name: String) -> Double? {
        if let raw = params?["\(name)Bytes"], let bytes = Int(raw), bytes > 0 {
            return Double(bytes) / (1024 * 1024)
        }
        let parts = params?[name]?.split(separator: " ") ?? []
        guard parts.count == 2, parts[1] == "MB",
              let value = Double(parts[0]), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// A sentence naming `params.commodity` in Bulgarian, or the general one.
    private static func commodityNamed(_ params: [String: String]?, _ format: String,
                                       otherwise: String) -> String {
        guard let name = params?["commodity"].flatMap({ CommodityName.canonical($0) }) else { return otherwise }
        return format.replacingOccurrences(of: "%@", with: name)
    }

    /// `PESTICIDE_REGULATORY_FIELDS_REQUIRED`'s `params.missing`, wire name →
    /// what the sheet calls the field.
    static let regulatoryFieldNames = [
        "pppRegistrationNo": "рег. № по ЗЗР",
        "quarantinePeriodDays": "карантинен срок",
    ]

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

        // ── Parcel-boundary upload (agri-saas #1633) ──
        //
        // No file part reached the server. Its sibling `FILE_EMPTY` (one did,
        // with no bytes) is in Batch 1 below; the phone refuses an empty file
        // itself, so that one is a backstop.
        "FILE_REQUIRED": "Файлът не стигна до сървъра. Изберете го и опитайте отново.",
        // The poll. The server gives the SAME answer for a job that never
        // existed and one belonging to another farm, so job ids cannot be
        // probed across farms. There is no reason to give, only what to do.
        "IMPORT_JOB_NOT_FOUND": "Сървърът не намира това импортиране. Качете файла отново.",

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
        // The per-decare refusals (`PerAreaRefusalCode`, agri-saas
        // `per-area.ts`), in the web's words (`grain.calculator.perAreaNoArea`
        // / `perAreaNoValue`).
        // Since agri-saas #1606 the cost per dca is given under both codes;
        // only value and margin are refused, and the words say exactly that
        // (the web's, mirrored).
        "NO_STANDING_CROP_AREA": "Няма площ с прогноза за добив, затова стойността и маржът на декар не се изчисляват.",
        "NO_STANDING_CROP_VALUE": "Няма пазарна цена за реколтата на корен, затова стойността и маржът на декар не се изчисляват.",
        // Why the COST per decare is missing (agri-saas #1614's
        // `costRefusalCode`, a separate vocabulary from the two above), in
        // the web's words (`grain.calculator.costPerDcaNoArea` /
        // `costPerDcaMixedCurrency` / `costPerDcaCurrencyUnrecorded`).
        "NO_OCCUPIED_AREA": "Няма парцел, записан с тази култура, затова разходът на декар не се изчислява. Укажете културата върху парцелите, където е засета.",
        "COST_CURRENCY_MIXED": "Разходите за тази култура са записани в повече от една валута, затова разходът на декар не се изчислява — събирането им би го изкривило.",
        "COST_CURRENCY_UNRECORDED": "Валутата на арендата не е записана в договора, затова разходът на декар не се изчислява.",
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
        // Coded since agri-saas #1767, where it was a bare FORBIDDEN with an
        // English message: a role that cannot change records. The role is
        // named when it can be (`interpolated`).
        "WRITE_FORBIDDEN_FOR_ROLE":
            "Ролята Ви в това стопанство не позволява промени. Друга роля може да Ви даде администратор на стопанството.",
        // Coded since agri-saas #1779: an operation inside a route the role
        // may use, which needs an administrator (or, for the audit one, an
        // auditor). Not the Edge's ADMIN_REQUIRED below, which shuts the
        // whole route: telling an editor «това е достъпно само за
        // администратор» about a screen they are looking at would be false.
        "ADMIN_FORBIDDEN_FOR_ROLE":
            "Това действие е само за администратор на стопанството. Друга роля може да Ви даде администратор на стопанството.",
        "AUDIT_FORBIDDEN_FOR_ROLE":
            "Това действие е за одитор или администратор на стопанството. Друга роля може да Ви даде администратор на стопанството.",

        // ── The middleware's own 403s (agri-saas `src/middleware.ts`) ──
        //
        // Reachable on EVERY route, and each carries an English sentence as
        // its message, which `httpText` would have shown: of the codes
        // documented on the routes this app builds, these three were the
        // only ones without a sentence here (measured 2026-10-11).
        //
        // The route is admin-only and this member's role is not.
        "ADMIN_REQUIRED": "Това е достъпно само за администратор на стопанството.",
        // The session has not cleared the farm's second factor. Google and
        // Microsoft sign-in ask for the code inside their sheet (agri-saas
        // #1644), so signing in again is the step that clears it. Apple
        // sign-in's own refusal has its own words (`AppleSignIn.Text`).
        "MFA_REQUIRED": "Стопанството изисква двуфакторно потвърждение. Излезте и влезте отново, за да въведете кода.",
        // A cross-site admin request. The app sends a bearer from no site,
        // so this should be unreachable; the server says a retry will not
        // help, and the sentence does not offer one.
        "CSRF_BLOCKED": "Сървърът отказа заявката от съображения за сигурност.",
        // Account deletion (agrent-ios#281): the grace period is over and the
        // account was pseudonymised, so there is nothing to cancel or ask
        // for. Said, rather than offering a button that cannot work.
        "ACCOUNT_ALREADY_ERASED": "Профилът вече е изтрит и не може да бъде възстановен.",
        // Every request of a suspended account — a moderator's suspension,
        // or a termination, which also starts the erasure (agri-saas P5.9,
        // `getSessionOrThrow`). Its message is the bare code, so without this
        // the person was told «Нямате права», as if a role were missing.
        "ACCOUNT_SUSPENDED": "Профилът Ви е спрян и не може да се използва.",
        // The cancel of an erasure a moderator started, by terminating the
        // account (agri-saas #1670/#1671). Its own code so that nothing here
        // reads as an appeal: says who decided and that the person cannot
        // stop it — true whether the account is still suspended or not.
        "ACCOUNT_TERMINATED": "Профилът се изтрива по решение на модератор. Не можете да спрете изтриването.",

        // 409s that are not a stale edit (#240, agri-saas #1489): a collision
        // with something that already exists, so the remedy is a different
        // name or the thing already there, never a re-read.
        "ITEM_NAME_ALREADY_EXISTS": "Вече има продукт с това име. Въведете друго име.",
        "LISTING_INTEREST_ALREADY_SENT": "Вече сте изпратили запитване за тази обява.",
        "CONFLICT": "Това вече съществува на сървъра.",

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
        // The spray sheet's typed product (#237). The server's category rule
        // is ONE-SIDED — only a FERTILIZER on the fertiliser path; the product
        // path takes anything — and the sheet applies it before the request
        // too (`TypedProduct.wrongKind`); this is for a record queued before
        // the catalogue arrived. There is no `PRODUCT_EXPECTED`: the server
        // shipped one briefly and dropped it (a fertiliser can be a spray).
        "FERTILIZER_EXPECTED": "Това не е тор. Запишете операцията като „Пръскане“.",
        "OPERATION_INPUT_AMBIGUOUS": "Операцията трябва да има или препарат, или тор — не и двете.",
        // A name the sheet sends trimmed and non-empty can still be nothing
        // once the server strips markup from it (agri-saas #1499).
        "PRODUCT_NAME_REQUIRED": "Въведете търговското наименование на продукта.",
        // The dose picker offers only rate units (`?measure=RATE`); this is
        // the server's backstop should one not be a quantity per area.
        "DOSE_UNIT_HAS_NO_BASE": "Мерната единица на дозата трябва да е количество на площ — например л/дка или кг/дка.",

        // ── «Ново мероприятие» (agrent-ios#293, agri-saas #1740) ──
        //
        // The form asks for a date, not in the future, and at least one
        // parcel before the request, so the first three mean its rule and
        // the server's have drifted. One way they can: the server reads
        // «today» off the farm's clock and the phone off its own, so a phone
        // in a later time zone is told its own today is the future — and the
        // form's sentence still says what to do.
        "TREATMENT_DATE_INVALID": "Датата на мероприятието не е валидна. Изберете я отново.",
        "TREATMENT_DATE_IN_FUTURE": TreatmentDraft.Problem.futureDate.text,
        "TREATMENT_NO_PARCELS": "Изберете поне един парцел.",
        // agri-saas #2086: a parcel's treated area above its own (inclusive
        // bound). The phone checks first, so this is the server disagreeing
        // about a parcel's area, and the advice is the same.
        "TREATMENT_AREA_EXCEEDS_PARCEL": "Третираната площ не може да надвишава площта на парцела. "
            + "Въведете по-малка площ или оставете полето празно за целия парцел.",
        "REFERENCE_NOT_IN_TENANT": "Нещо от избраното вече не е в това стопанство. Проверете избора и опитайте отново.",
        // The operation write underneath, on this route and the spray
        // sheet's. Both send a name and a dose always, so these are the
        // server's backstop — and had only its English until now.
        "PRODUCT_DOSE_REQUIRED": "Въведете дозата на препарата.",
        "FERTILIZER_DOSE_REQUIRED": "Въведете дозата на тора.",
        "PRODUCT_NOT_FOUND": "Препаратът не е намерен. Може да е изтрит.",
        "FERTILIZER_NOT_FOUND": "Торът не е намерен. Може да е изтрит.",
        // «Изтегли PDF» on a saved treatment (agri-saas #1822): the server
        // holds no recorded line under the handle, so there are no ДНЕВНИК
        // pages to give. The read by handle answers this code too, and reads
        // it as "nothing landed" itself — it never reaches a person there.
        "TREATMENT_NOT_FOUND": "Мероприятието не е намерено на сървъра. Може да е изтрито.",
        // «Дневник (PDF)» for a block with nothing in the period (agri-saas
        // #2183, #402). `FarmRecordSheet` shows it as a note, not an error;
        // the sentence is here for any other surface that meets the code.
        "REGISTER_EMPTY_FOR_PERIOD": "Няма записи за този период.",
        // A resend under the handle of a treatment an administrator abandoned
        // because it could not be finished (agri-saas #1869, agrent-ios#326):
        // a 410, and the row is never sent again. Mostly met by an outbox row
        // that kept coming back short, whose copy is the only one left, so the
        // sentence says what became of it and what to do if the work still
        // belongs in the register: a new entry, which goes out under a new key.
        "TREATMENT_ABANDONED":
            "Администратор прекрати това мероприятие, защото не можеше да бъде записано докрай. "
            + "Ако работата трябва да е в дневника, направете нов запис.",
        // The abandon met a treatment that finished meanwhile (agri-saas
        // #1860). A server since #2184 removes a complete treatment through
        // the same route and no longer answers this; an older one still can,
        // to a phone that asked before it was deployed.
        "TREATMENT_COMPLETE": "Мероприятието вече е записано изцяло, затова не може да бъде прекратено.",
        // A Дневник row's «Изтрий» (agri-saas #2184, agrent-ios #395), in the
        // server's own words, which the web shows. The phone offers it where
        // the row's `mayDelete` says yes; this is the route checking again.
        // A task's «Изтрий» (#454, agri-saas #2187/#2396), in the server's
        // words. The phone offers it where the row's `mayDelete` allows, so
        // these are the route checking again.
        "TASK_DELETE_NOT_PERMITTED":
            "Само човекът, създал тази задача, или администратор на стопанството може да я изтрие.",
        "TASK_BELONGS_TO_TREATMENT":
            "Тази задача е частта за един блок от записано мероприятие. Изтрийте цялото мероприятие — иначе ще остане наполовина записано.",
        "TREATMENT_DELETE_NOT_PERMITTED":
            "Само човекът, записал това мероприятие, или администратор на стопанството може да го премахне.",
        // «Коригирай» (agri-saas #2283/#2287, agrent-ios #392), in the
        // server's own words. The phone offers it where the row allows; these
        // are the route checking again.
        // Kind-neutral since agri-saas #2375, which reuses it for pruning,
        // cultivation and a harvest.
        "TREATMENT_EDIT_NOT_PERMITTED":
            "Само човекът, който е направил записа, или администратор на стопанството може да го коригира.",
        // «Коригирай» on other work (agri-saas #2375), in the server's words.
        // The phone picks the route by the row's kind and sends a total only
        // on a harvest, so these are the route checking again.
        "ACTIVITY_NOT_FOUND": "Няма записано мероприятие с този идентификатор.",
        "ACTIVITY_MIXED_AUTHORSHIP":
            "Мероприятието е записано от повече от един човек и не може да се коригира наведнъж. "
            + "Ограничението важи и за администраторите.",
        "NOT_AN_ACTIVITY": "Записът влага продукт, тоест е третиране, а не мероприятие. Коригирайте го от третирането.",
        "HARVEST_TOTAL_NOT_APPLICABLE":
            "Само прибирането на реколтата има количество. Запишете добива към прибирането, а не към това мероприятие.",
        // Its parcels (agri-saas #2386). The phone sends no empty set and
        // only the farm's own blocks, so these are the route checking again.
        "ACTIVITY_CORRECTION_WOULD_EMPTY":
            "Корекцията не може да премахне всички парцели. Изтрийте мероприятието вместо това.",
        "ACTIVITY_CORRECTION_BLOCK_UNRESOLVED": "Този парцел не може да бъде отнесен към блок на мероприятието.",
        // Other work (#439, agri-saas `/journal/activities`), in the server's
        // words. The phone sends no product with it, so the first is the
        // route checking again; the second can meet a harvest.
        "ACTIVITY_APPLIES_NO_INPUT":
            "Това мероприятие не използва продукт или торов продукт. Запишете го като пръскане или торене, "
            + "ако е приложен такъв.",
        "HARVEST_NOT_RECORDED":
            "Мероприятието не създаде запис в дневника, затова количеството не можа да се запише. "
            + "Проверете дали е отбелязано като извършено.",
        // «Сеитба» (agri-saas #2368), in the server's words. The phone takes
        // only a seed for a sowing and asks no sowing's ДНЕВНИК page, so these
        // are the server checking again, or another client's refusal.
        "SEED_EXPECTED":
            "Избраният артикул не е семе. Сеитбата записва сорт семе — запишете приложен продукт като пръскане или торене.",
        "NOT_IN_BABH_REGISTER":
            "Сеитбата не е част от дневника на БАБХ, който обхваща растителна защита и торене. "
            + "Тя се вижда в дневника на стопанството.",
        // The parcel set (agri-saas #2304). The phone offers neither, so these
        // are the route checking again, or another client's refusal.
        "TREATMENT_CORRECTION_WOULD_EMPTY":
            "Корекцията не може да премахне всички парцели. Вместо това премахнете мероприятието.",
        "TREATMENT_CORRECTION_NEW_BLOCK":
            "Корекцията може да добави парцел само в блок, който това мероприятие вече покрива. "
            + "Запишете другия блок като отделно мероприятие.",
        "TREATMENT_TITLE_REQUIRED":
            "Мероприятието трябва да има наименование. Изчистете другите полета или премахнете мероприятието.",
        // Tasks of one treatment recorded by different people, so "its
        // creator" names nobody. Refused for «Изтрий» and «Коригирай» alike,
        // administrators included, so the server's words since agri-saas
        // #2292 name both and send nobody to an administrator.
        "TREATMENT_MIXED_AUTHORSHIP":
            "Това мероприятие е записано от повече от един човек, затова не може да бъде коригирано или "
            + "премахнато наведнъж. Ограничението важи и за администраторите.",

        // «Публичен профил» (agrent-ios #323, agri-saas #1865/#1871). The
        // address is the one field another farm can refuse: the taken case
        // shows its alternatives beside this (`PublicAddressSheet`).
        "FARM_BRAND_NOT_FOUND": "Профилът още не е създаден. Запазете го веднъж и опитайте отново.",
        "FARM_HANDLE_TAKEN": "Този адрес вече е на друго стопанство. Изберете друг.",
        "FARM_HANDLE_RESERVED": "Този адрес е запазен и не може да бъде използван. Изберете друг.",
        "FARM_HANDLE_TOO_SHORT": "Адресът трябва да е поне 3 знака, след като се изпише с латински букви.",
        "FARM_HANDLE_TOO_LONG": "Адресът може да е най-много 40 знака, след като се изпише с латински букви.",
        "FARM_HANDLE_UNUSABLE": "Адресът трябва да съдържа букви или цифри.",
        // What publishing and the A6 card (agri-saas #1910) both need first,
        // so the sentences name neither. The phone offers the card only on a
        // published page with an address, which leaves a change made on the
        // web in between: the page taken down, the name cleared.
        "FARM_BRAND_HANDLE_REQUIRED": "Първо изберете адрес на страницата.",
        "FARM_BRAND_DISPLAY_NAME_REQUIRED": "Първо попълнете името, което страницата показва.",
        // Publishing without a recorded consent. The phone asks for it first
        // unless the farm agreed to this text already, so this is the server
        // knowing better than the draft the phone read.
        "FARM_BRAND_CONSENT_REQUIRED":
            "Публикуването изисква съгласие. Натиснете «Публикувай» отново и потвърдете текста.",
        "FARM_BRAND_NOT_PUBLISHED":
            "Страницата не е публикувана. Карта за печат се прави само за публикувана страница, "
            + "иначе отпечатаният адрес няма да се отваря.",

        "TERMS_ACCEPTANCE_REQUIRED":
            "Трябва да приемете условията за ползване. Отворете уеб приложението, "
            + "приемете ги и опитайте отново.",

        // A failed payment (agrent-ios#241): after a 14-day grace the server
        // withholds named capabilities — the exchange, trends, creating
        // tasks, uploads and journal entries — with a 403 of this code, and
        // its message is English. Said as a FACT and nothing more: App Store
        // guideline 3.1.1 rules out sending anyone to pay outside the app,
        // and the member who meets it could not pay anyway. NOT a missing
        // right, which would send them to the owner for the wrong reason.
        "PAST_DUE_RESTRICTED":
            "Тази функция е спряна, защото плащането за абонамента на стопанството не е преминало.",

        // The plan's other refusals, coded since agri-saas #1679 (agrent-ios
        // #286). Before that the plan limit was a bare FORBIDDEN, told apart
        // by its message's leading token; the server has dropped the token
        // (agri-saas #1677) and the match on it went with it (#307) — the
        // code alone decides. Under the same 3.1.1 rule as above: no plan picker, no
        // "upgrade" — and each says what is true of ITS condition, because
        // the five differ in what, if anything, changes it.
        //
        // Waiting changes nothing. `params` names the resource only in wire
        // words, so the sentence does not quote it.
        "PLAN_LIMIT_EXCEEDED": planLimitReached,
        // The one that waiting does lift: a token cap per UTC month, so
        // «next month» is honest. Not «from the 1st»: in Bulgaria the UTC
        // month turns at 02:00 or 03:00 that day.
        "AI_BUDGET_EXCEEDED":
            "Месечният лимит за функциите с изкуствен интелект е изчерпан. "
            + "Той се подновява в началото на следващия месец.",
        // Refused on capability, not spend, so the month changes nothing.
        // The app picks no tier, so there is no other choice to point at.
        "AI_TIER_NOT_ALLOWED":
            "Тази функция с изкуствен интелект не е включена в абонаментния план на стопанството.",
        // Refused when the module is not AVAILABLE, which is two conditions
        // in one code: the farm switched it off (an administrator can switch
        // it back on), or the plan does not include it (no administrator
        // can). `params.reason` tells them apart (`interpolated`); this is
        // for a refusal without it, so it names nobody: sending a farmer to
        // an administrator who cannot help is the #241 mistake. «Не е
        // включена» holds for both.
        "MODULE_DISABLED": "Тази част от приложението не е включена за стопанството.",
        // A self-hosted installation, which has no plans at all. Nothing
        // the farmer or a retry can change, and nothing to offer.
        "BILLING_UNAVAILABLE": "В тази инсталация на Agrent няма абонаментни планове.",

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
        // agri-saas #2541/#2543 (2026-10-31): the exchange's refusals, which
        // reached the phone as BAD_REQUEST with the code in `message` until
        // then. The server sends these sentences itself for a `bg` session
        // (#1677); they are copied here word for word from its catalogue
        // (`messages/bg/app.json` `errors.*`, a75203659) so the phone and the
        // web say one thing, and kept because an `en` account would get the
        // English and this app shows none (owner, 2026-10-13).
        "LISTING_TERMINAL": "Обявата вече е оттеглена или изпълнена и не може да се променя.",
        "LISTING_NOT_OWNED": "Можете да променяте само своите обяви.",
        "LISTING_MODIFIED": "Обявата е променена, откакто я отворихте. Презаредете я и направете промяната отново.",
        "LISTING_REGION_UNKNOWN": "Непозната област.",
        "LISTING_EXPIRES_AT_IN_PAST": "Изберете дата на изтичане в бъдещето или я премахнете.",
        // One code for three refusals until agri-saas #2564 splits it: this
        // one stays for the buyer's inquiry, neutral, and the two below take
        // the seller's fulfil and the seller's accept, each with the sentence
        // that is right only there. Entered before the server sends them, so
        // the phone is ready when it does.
        "LISTING_NOT_ACTIVE": "Обявата вече не е активна.",
        "LISTING_FULFIL_REQUIRES_ACTIVE": "Обявата е изтекла — оттеглете я, вместо да я отбелязвате като изпълнена.",
        "INQUIRY_ACCEPT_REQUIRES_ACTIVE_LISTING": "Обявата вече не е активна — можете да откажете, но не да приемете.",
        "LISTING_EXPIRED": "Обявата е изтекла.",
        "LISTING_IS_YOUR_OWN": "Това е Вашата обява — не можете да изпратите запитване към нея.",
        "INQUIRY_NOT_PENDING": "Запитването вече е обработено.",
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
        "INVALID_LOCATION": "Блокът не е намерен или принадлежи на друго стопанство.",
        "INVALID_PARCEL": "Парцелът не е намерен или принадлежи на друго стопанство.",
        "INVALID_PLANTING": "Засаждането не е намерено или принадлежи на друго стопанство.",
        "INVALID_SEASON": "Сезонът не е намерен или принадлежи на друго стопанство.",
        "INVALID_TASK": "Задачата не е намерена или принадлежи на друго стопанство.",
        "INVALID_VARIETY": "Сортът не е намерен или принадлежи на друго стопанство.",
        "PARCEL_LOCATION_MISMATCH": "Парцелът не принадлежи на този блок.",

        // ── Coded but undocumented (agri-saas, measured 2026-10-11) ──
        //
        // Backend 1 crossed its undocumented-codes baseline with the paths
        // this app builds: 49 reachable, and these 24 had no sentence here,
        // so their English `message` reached the screen. The attribution is
        // by import reachability, so some may never fire from this app;
        // a sentence costs nothing where it does not.
        //
        // Journal.
        "JOURNAL_TITLE_REQUIRED": "Въведете заглавие на записа.",
        "JOURNAL_ENTRY_NOT_FOUND": "Записът в дневника не е намерен. Може да е изтрит.",
        // No JOURNAL_ENTRY_NOT_DELETED or …_NOT_SOFT_DELETED any more: they
        // were the restore's and the purge's, retired with «Кошче» (agri-saas
        // #2254; the owner, 2026-10-24: "what's deleted is deleted").
        "JOURNAL_FILE_LINK_NOT_FOUND": "Файлът вече не е прикачен към този запис.",
        // Field operations: creating one, and reviewing it.
        "LOCATION_NOT_FOUND": "Блокът не е намерен. Може да е изтрит.",
        "PARCELS_NOT_IN_LOCATION": "Някои от избраните парцели не са в този блок.",
        "DOSE_UNIT_NOT_FOUND": "Мерната единица на дозата не е намерена. Изберете я отново.",
        "WATER_RATE_UNIT_REQUIRED": "Изберете мерна единица за работния разтвор.",
        "WATER_RATE_UNIT_NOT_FOUND": "Мерната единица на работния разтвор не е намерена. Изберете я отново.",
        "NOT_A_FIELD_OPERATION_TASK": "Оттук се преглеждат само земеделски операции.",
        // `params.status` is the task's current status, a wire name; not
        // quoted. The task moved on while the screen was open.
        "TASK_NOT_AWAITING_REVIEW": "Задачата вече не чака преглед. Обновете списъка.",
        // «Редактирай» on a task someone else created (agri-saas #2182, live
        // 2026-10-22). The phone offers the pencil only to the creator and an
        // administrator, the same rule, so this is met only when that changed
        // while the screen was open. The server's own words.
        "TASK_EDIT_NOT_PERMITTED":
            "Само човекът, създал тази задача, или администратор на стопанството може да я редактира.",
        // A parcel's history: crops by year and weed observations.
        "CROP_TYPE_INVALID": "Посочете културата.",
        "CROP_SEASON_YEAR_INVALID": "Годината на реколтата е извън допустимия диапазон.",
        "NOTES_TOO_LONG": "Бележките са твърде дълги.",
        "WEED_ENTRIES_TOO_MANY": "Твърде много плевели в едно наблюдение.",
        "WEED_NAME_TOO_LONG": "Името на плевела е твърде дълго.",
        // Reachable only through a defect in this app: it builds the
        // If-Match, the page size and the review action itself, and signs in
        // with a bearer, never an API key. Nothing for the farmer to fix, so
        // each says the request was refused and what to do next, as
        // IDEMPOTENCY_KEY_INVALID does.
        "IF_MATCH_EMPTY": "Промяната не беше запазена заради техническа грешка. Обновете и опитайте отново.",
        "IF_MATCH_MALFORMED": "Промяната не беше запазена заради техническа грешка. Обновете и опитайте отново.",
        "IF_MATCH_WEAK_TAG": "Промяната не беше запазена заради техническа грешка. Обновете и опитайте отново.",
        "INVALID_LIMIT": "Списъкът не можа да се зареди заради техническа грешка.",
        "INVALID_REVIEW_ACTION": "Прегледът не беше приет заради техническа грешка. Опитайте отново.",
        "API_KEY_WRONG_SURFACE": "Сървърът отказа достъпа за тази заявка.",
        "API_KEY_FAMILY_NOT_ENABLED": "Сървърът отказа достъпа за тази заявка.",

        // Three refusals that reached the client as `FORBIDDEN` — the token
        // sat in `message` — until agri-saas #1645 made each its own code
        // and gave it an English sentence as `message`. Without a sentence
        // here a code would have replaced «Нямате права» with the generic
        // status line: less specific than the right sentence, which is this
        // one.
        //
        // A machine operator (MECHANISATOR) is confined to its own work; a
        // person-scoped social route refuses that persona.
        "OPERATOR_SCOPE": "Това не е достъпно за механизатори.",
        // An API key on a person's route. This app never sends one — it signs
        // in as a person — so this is for completeness, in the API-key words.
        "API_KEY_NOT_PERSON_SCOPED": "Сървърът отказа достъпа за тази заявка.",
        // No AI budget for a self-registered farm until it is verified (OD11).
        "AI_BUDGET_REQUIRES_VERIFIED_FARM":
            "Функциите с изкуствен интелект са достъпни, след като стопанството бъде потвърдено.",
    ]
}
