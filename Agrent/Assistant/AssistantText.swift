import Foundation

/// Every word the assistant's sheet says that the model does not (#483).
/// Bulgarian only (owner, 2026-10-13): the stream carries CODES for its
/// refusals and stops, never prose, so each has its sentence here.
enum AssistantText {
    static let title = "Асистент"
    static let prompt = "Попитайте за стопанството…"
    static let intro = "Питайте за задачите, Дневника, разходите, Калкулатора, Риска, Борсата и цените. "
        + "Асистентът чете данните на стопанството и не променя нищо."

    // MARK: - While a turn runs

    static let thinking = "Мисля…"
    static let reading = "Чета данните на стопанството…"

    /// What the wait says while a tool runs (owner, 2026-11-01: "a bit slow
    /// in answering"): the data being read, by the tool's name, so twenty
    /// seconds read as work being done rather than a stuck screen. A tool
    /// this build does not know is the general sentence above.
    static func reading(_ tool: String) -> String {
        switch tool {
        case "list_farm_tasks": "Чета задачите…"
        case "list_journal_entries": "Чета дневника…"
        case "list_blocks": "Чета блоковете…"
        case "analyze_block_risk": "Проверявам риска по парцелите…"
        case "grain_calculator": "Смятам в калкулатора…"
        case "list_cost_entries": "Чета разходите…"
        case "list_exchange_listings": "Чета обявите в Борса…"
        case "price_trends": "Проверявам цените…"
        case "propose_activity", "propose_treatment": "Подготвям записа…"
        default: reading
        }
    }

    /// After the data is read and before the answer arrives: the model
    /// writing it, which is the longest single wait.
    static let writing = "Пиша отговора…"

    /// The connection went while the answer was coming (`AssistantKeepAlive`
    /// covers a short trip out of the app; this is past it, or the signal).
    static let lostMidAnswer = "Връзката прекъсна, преди отговорът да пристигне. Задайте въпроса отново."

    // MARK: - How a turn ended

    // ── The server's own sentences ──
    //
    // agri-saas #2595's catalogue (`messages/bg/app.json`, `errors.*`), word
    // for word. The server sends them itself, in the person's language; the
    // phone shows THAT when it is Bulgarian, and these only when it is not
    // — an `en` account, or an older server — because the phone shows no
    // English (owner, 2026-10-13). A copy pinned by test, never a second
    // wording.

    /// `refusal.reason`: no answer, and not a fault.
    static func refusal(_ code: String) -> String {
        switch code {
        case "ASSISTANT_NO_GROUNDING":
            "Не намерих нищо в данните на стопанството, с което да отговоря, и няма да предполагам."
        case "ASSISTANT_OUT_OF_SCOPE":
            "Това е извън онова, на което мога да отговоря от данните на стопанството."
        case "ASSISTANT_HIGH_STAKES_NEEDS_SOURCE":
            "Тук е нужна точна стойност от етикета на регистриран продукт, а аз не разполагам с такава. "
                + "Проверете етикета или се консултирайте с агроном."
        case "ASSISTANT_EGRESS_BLOCKED":
            "Спрях този отговор, защото изглеждаше, че съдържа идентификационни данни. Нищо не беше изпратено."
        case "ASSISTANT_INPUT_REJECTED":
            "Не можах да прочета въпроса безопасно. Опитайте да го формулирате иначе."
        default:
            "Асистентът не отговори на този въпрос."
        }
    }

    /// `halt.outcome`: the answer above is real but incomplete — except a
    /// provider failure, which can come before any answer, and says so.
    static func halt(_ outcome: String, counts: [String: Int] = [:]) -> String {
        switch outcome {
        case "ASSISTANT_TOOL_BUDGET":
            "Отговорът по-горе е верен, но непълен — достигнах ограничението колко мога да проверя за един въпрос."
        case "ASSISTANT_SPEND_CEILING":
            "Отговорът по-горе е непълен, защото стопанството достигна месечния си лимит за асистента."
        case "ASSISTANT_TIME_BUDGET":
            "Отговорът по-горе е непълен — отнемаше твърде дълго и спрях, вместо да Ви карам да чакате."
        case "ASSISTANT_PROVIDER_UNAVAILABLE":
            "Не успях да се свържа с модела. Данните на стопанството не бяха прочетени и нищо не беше създадено."
        case "ASSISTANT_TRUNCATED_RESULT":
            "Отговорът по-горе използва част от данните — един от списъците, които прочетох, беше твърде дълъг, "
                + "за да го използвам цял."
        // agri-saas #2648 (#490): a read that did not gather everything that
        // exists, such as satellite risk for 24 of a block's 30 parcels. Not
        // the truncation above: there the list was read and then shortened.
        // agri-saas #2663 (#506): the model REFUSED the request (a 400),
        // which used to come back as «could not reach the model». Ours, not
        // the person's, and it says so.
        case "ASSISTANT_REQUEST_REJECTED":
            "Моделът отказа заявката, така че няма отговор и нищо не беше създадено. "
                + "Това е наша грешка, не Ваша — моля, съобщете за нея."
        case "ASSISTANT_PARTIAL_DATA":
            "Отговорът по-горе е непълен — част от Вашите записи не можаха да бъдат включени, "
                + "така че го приемете като частична картина."
        default:
            "Отговорът е непълен."
        }
    }

    /// The sentence a refusal or a halt shows: the server's own, when it
    /// sent one in Bulgarian; the copy above otherwise.
    static func said(_ message: String?, else copy: String) -> String {
        if let message, UserMessage.isBulgarianSentence(message) { return message }
        return copy
    }

    // ── A prepared entry ──

    static let openEntry = "Отвори в «Нов запис»"
    static let preparedNote = "Асистентът попълни записа. Проверете го, изберете парцелите и мерната единица и го запазете."

    /// `done` with no answer before it.
    static let noAnswer = "Асистентът няма отговор на този въпрос."

    /// The connection closed with no `refusal`, `halt` or `done`: the server
    /// never says "error", so this is the transport and nothing else.
    static let interrupted = "Връзката прекъсна, преди асистентът да довърши. Опитайте отново."

    /// 204: the route is off for this person.
    static let switchedOff = "Асистентът не е включен за това стопанство."

    /// The turn, as VoiceOver hears the answer arrive.
    static func answered(_ text: String) -> String { "Асистентът отговори: \(text)" }
}
