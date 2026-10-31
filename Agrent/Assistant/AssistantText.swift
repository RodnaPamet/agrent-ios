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

    // MARK: - How a turn ended

    /// `refusal.reason`: a guard stopped the turn after the stream opened.
    static func refusal(_ code: String) -> String {
        switch code {
        case "ASSISTANT_INPUT_REFUSED":
            "Въпросът не може да бъде обработен. Задайте го с други думи."
        case "ASSISTANT_EGRESS_REFUSED":
            "Отговорът беше спрян, защото съдържаше данни, които не бива да се показват. Попитайте по-конкретно."
        default:
            "Асистентът не отговори на този въпрос."
        }
    }

    /// `halt.outcome`: a bound was reached. What came before it is real but
    /// incomplete, and is said as such — not as an error, not as a success.
    static func halt(_ outcome: String, counts: [String: Int]) -> String {
        switch outcome {
        case "MAX_TOOL_CALLS":
            if let calls = counts["toolCalls"] {
                return "Отговорът е непълен: асистентът провери данните \(calls) пъти — колкото е позволено за един въпрос."
            }
            return "Отговорът е непълен: асистентът провери данните колкото е позволено за един въпрос."
        case "TOKEN_CEILING":
            return "Отговорът е непълен: достигна най-голямата позволена дължина."
        case "TIME_BUDGET":
            return "Отговорът е непълен: отне повече време, отколкото е позволено за един въпрос."
        case "PROVIDER_UNAVAILABLE":
            return "Асистентът не е достъпен в момента. Данните не са прочетени и нищо не е променено."
        default:
            return "Отговорът е непълен."
        }
    }

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
