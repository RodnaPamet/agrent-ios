import Foundation

/// The calendar's words: agri-saas `messages/bg/app.json` `lunar.*` (#3073),
/// copied so the phone and the web say the same thing. The server sends
/// keys; anything it sends that is not here is shown as nothing.
enum LunarWords {
    enum Group: String, CaseIterable, Sendable {
        case field, vegetable, perennial

        var title: String {
            switch self {
            case .field: "Полски култури"
            case .vegetable: "Зеленчукови"
            case .perennial: "Трайни насаждения"
            }
        }
    }

    static let title = "Лунен календар"
    static let traditionTitle = "По лунния календар"
    static let traditionNotice = "Следва народната традиция. Не е агрономски съвет и не замества преценката Ви за времето и състоянието на посевите."
    static let nothing = "Традицията няма съвет за този ден."

    static let phases = ["waxing": "Растяща луна", "waning": "Намаляваща луна"]

    static let phaseNames = [
        "new": "Новолуние", "waxingCrescent": "Растящ сърп", "firstQuarter": "Първа четвърт",
        "waxingGibbous": "Растяща луна", "full": "Пълнолуние", "waningGibbous": "Намаляваща луна",
        "lastQuarter": "Последна четвърт", "waningCrescent": "Намаляващ сърп",
    ]

    static let dayTypes = ["root": "Коренов ден", "leaf": "Листен ден", "flower": "Цветен ден", "fruit": "Плоден ден"]

    static let elements = ["earth": "Земя", "water": "Вода", "air": "Въздух", "fire": "Огън"]

    static let signs = [
        "aries": "Овен", "taurus": "Телец", "gemini": "Близнаци", "cancer": "Рак", "leo": "Лъв", "virgo": "Дева",
        "libra": "Везни", "scorpio": "Скорпион", "sagittarius": "Стрелец", "capricorn": "Козирог",
        "aquarius": "Водолей", "pisces": "Риби",
    ]

    static let recommendations = [
        "soilWork": "Обработка на почвата.",
        "incorporateResidues": "Заравяне на растителните остатъци.",
        "sowBeetPotato": "Сеитба на цвекло и садене на картофи.",
        "sowCarrotRadishOnion": "Сеитба на моркови, репички, лук и чесън.",
        "rootPruning": "Подрязване на корените.",
        "liftNurseryStock": "Вадене и прикопаване на фиданки.",
        "sowForageGrass": "Сеитба на фуражни треви и житни за зелена маса.",
        "sowLeafyVeg": "Сеитба и разсаждане на зеле, салата, спанак и праз.",
        "leafFeeding": "Листно подхранване.",
        "grafting": "Присаждане.",
        "cutLeafyForUse": "Бране на листни зеленчуци за ядене.",
        "sowOilseedRape": "Сеитба на рапица и слънчоглед.",
        "sowFloweringVeg": "Сеитба и разсаждане на броколи и карфиол.",
        "cutFlowers": "Рязане на цветя.",
        "formativePruning": "Формираща резитба.",
        "sowCerealGrain": "Сеитба на житни за зърно, царевица и фасул.",
        "sowFruitingVeg": "Сеитба и разсаждане на домати, пипер, краставици и тикви.",
        "plantTreesVines": "Садене на плодни дървета и лози.",
        "harvestForStorage": "Бране на плодове за съхранение.",
        "harvestGrainForStorage": "Прибиране на зърно за съхранение.",
        "seedSaving": "Събиране на семена за посев.",
        "winterPruning": "Зимна резитба.",
    ]

    /// Putting something in the ground: what a frost or spray warning holds
    /// back (owner, 2026-11-15). Every `sow…` key, and planting trees.
    static func isSowing(_ key: String) -> Bool {
        key.hasPrefix("sow") || key == "plantTreesVines"
    }

    /// One line of advice. On a warned day the sowing lines stay, struck
    /// through (owner, 2026-11-15): the tradition's answer visible and
    /// visibly overridden, and a warned day never looks like a day the
    /// tradition says nothing for.
    struct Advice: Equatable, Hashable, Sendable {
        let text: String
        let struck: Bool
    }

    /// A group's advice: unknown keys dropped, sowing struck on a warned day.
    static func advice(_ day: LunarDay, _ group: Group, warned: Bool) -> [Advice] {
        day.recommendations.keys(group).compactMap { key in
            recommendations[key].map { Advice(text: $0, struck: warned && isSowing(key)) }
        }
    }

    /// Whether a warning strikes anything that day.
    static func heldBack(_ day: LunarDay) -> Bool {
        Group.allCases.contains { day.recommendations.keys($0).contains(where: isSowing) }
    }

    /// «Предупреждение за слана в 2 блока», and the spray warning beside it.
    static func warnings(_ warnings: LunarWarnings, on date: String) -> [String] {
        var lines: [String] = []
        let frost = warnings.frost(on: date), spray = warnings.spray(on: date)
        if frost > 0 { lines.append("Предупреждение за слана в " + Plural.bg(frost, "блок", "блока")) }
        if spray > 0 { lines.append("Неподходящ ден за пръскане в " + Plural.bg(spray, "блок", "блока")) }
        let other = warnings.other(on: date)
        if other > 0 { lines.append("Предупреждение в " + Plural.bg(other, "блок", "блока")) }
        return lines
    }

    /// Spoken after a struck line: VoiceOver does not read a strikethrough.
    static let struckSpoken = "не се препоръчва заради предупреждението"

    /// Where the forecast ends: «Прогноза за слана и пръскане има само до
    /// 17 ноември.» Nothing is claimed for the days after it.
    static func horizon(_ day: Date) -> String {
        "Прогноза за слана и пръскане има само до \(BgDate.dayMonth(day))."
    }

    /// The page's notes on what the warnings can and cannot say: where the
    /// forecast ends, the frost rule, a cut list, or why there are none.
    static func warningNotes(_ warnings: LunarWarnings, farmOpen: Bool) -> [String] {
        guard farmOpen else { return ["Предупрежденията за слана и пръскане се виждат, когато е избрано стопанство."] }
        guard warnings.known else { return ["Предупрежденията за слана и пръскане не можаха да се заредят. Сеитбата не е проверена спрямо тях."] }
        var notes: [String] = []
        if let day = warnings.horizon.flatMap(BgDate.parseISODay) {
            notes.append(horizon(day))
        } else {
            notes.append("Няма прогноза за времето за това стопанство, затова няма и предупреждения.")
        }
        if let threshold = warnings.frostThresholdC {
            notes.append("Слана: най-ниска температура \(Num.text(threshold)) °C или по-малко.")
        }
        if warnings.truncated {
            notes.append("Списъкът с предупреждения е непълен. Липсата на предупреждение не значи, че няма такова.")
        }
        return notes
    }

    /// «Коренов ден» or, on a day the sign changes, «Коренов ден до 14:20,
    /// после Цветен ден».
    static func dayType(_ day: LunarDay, calendar: Calendar = FarmRecordAPI.farmCalendar) -> String {
        guard let change = day.transitions.first, let after = dayTypes[change.toDayType] else {
            return dayTypes[day.dayType] ?? ""
        }
        // The type BEFORE the change: noon's reading if the change comes
        // after noon, otherwise the reading is already the new type.
        let noon = day.day(calendar: calendar) ?? change.at
        let before: String
        if change.at > noon {
            before = dayTypes[day.dayType] ?? ""
        } else {
            before = ""
        }
        let time = BgDate.time(change.at, in: calendar)
        guard !before.isEmpty else { return "\(after) от \(time)" }
        return before == after ? before : "\(before) до \(time), после \(after.lowercasedFirst)"
    }

    /// «Пълнолуние, Риби»: what the day's row says under its type.
    static func moon(_ day: LunarDay) -> String {
        [phaseNames[day.phaseName], signs[day.sign]].compactMap { $0 }.joined(separator: ", ")
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
