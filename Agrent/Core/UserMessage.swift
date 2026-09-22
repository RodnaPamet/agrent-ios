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
        case APIClient.APIError.http(let status, let code, let message):
            return httpText(status: status, code: code, message: message)

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
    static func httpText(status: Int, code: String?, message: String?) -> String {
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
    static let bulgarian: [String: String] = [
        // Calculator refusals. These four predate the migration and already
        // work this way on the web through `explainRefusal`, so the wording
        // is taken from there rather than invented here.
        "NO_MARKET_PRICE": "Няма пазарна цена за тази култура, затова стойността не може да се изчисли.",
        "MIXED_COST_CURRENCY": "Разходите са в различни валути, затова сборът не може да се изчисли.",
        "RENT_CURRENCY_UNRECORDED": "Валутата на рентата не е записана, затова стойността не може да се изчисли.",
        "COST_PRICE_CURRENCY_MISMATCH": "Валутата на разходите и на цената се различават, затова маржът не може да се изчисли.",

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
