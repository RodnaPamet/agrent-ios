import Foundation

/// The app's own few sentences under a parcel's «Риск» (owner, 2026-11-07:
/// "Add here the app-generated text as well"), beside the assistant's
/// longer analysis: what the two readings mean together, the likely cause,
/// and what to look at in the field. Instant and offline, the same words
/// for the same readings.
///
/// ── Why the pair, not each reading alone ──
///
/// The two indices answer different questions: NDVI how green the crop is,
/// NDMI how much water is in it. Read together they point at a cause. Weak
/// AND dry is drought; weak but not dry is something else (disease, pests,
/// weeds, hunger); green but dry is a drought on its way. So the sentences
/// are written per combination.
///
/// ── Bare ground is not a sick crop ──
///
/// After harvest, and before an autumn crop is up, a field is soil: low
/// greenness and low moisture by definition. Said every time greenness is
/// low, because the readings cannot tell a bare field from a failing one.
/// The owner's own first screenshot was a bare November field reading
/// «Стрес» twice.
///
/// Pure, so `RiskExplanationTests` pins every case.
enum RiskExplanation {
    static func text(vegetation: RiskLevel, moisture: RiskLevel, stale: Bool) -> String? {
        var sentences: [String] = []
        switch (vegetation, moisture) {
        case (.unknown, _), (_, .unknown):
            return stale
                ? nil
                : "Сателитът няма ясна снимка на парцела (облачно или без данни), затова няма оценка. Проверете отново след следващото заснемане."
        case (.good, .good):
            sentences.append("Културата е зелена и има достатъчно влага: няма признаци на проблем.")
        case (.good, .watch):
            sentences.append("Културата е зелена, но влагата намалява. Следете следващите снимки: при сухо време зеленината спада след влагата.")
        case (.good, .stress):
            sentences.append("Културата още е зелена, но влагата е ниска: растенията все още не показват стрес, но сушата идва. Проверете влагата в почвата.")
        case (.watch, .good), (.watch, .watch):
            sentences.append("Зеленината е под нормалното. Сравнете с другите парцели със същата култура и огледайте за петна, болести или плевели.")
        case (.watch, .stress):
            sentences.append("Зеленината спада и влагата е ниска: най-вероятно растенията започват да страдат от суша.")
        case (.stress, .good), (.stress, .watch):
            sentences.append("Слаба зеленина при достатъчно влага: причината вероятно не е сушата. Проверете за болести, неприятели, плевели или недостиг на хранене, например азот.")
        case (.stress, .stress):
            sentences.append("Слаба зеленина и сухо: ако на парцела има култура, тя най-вероятно страда от засушаване. Проверете влагата в почвата и дали растенията вехнат.")
        }
        if vegetation == .watch || vegetation == .stress {
            sentences.append("Ако полето е празно (след жътва, обработено или преди поникване), ниската зеленина е нормална.")
        }
        if stale {
            sentences.append("Снимката е отпреди повече от \(Staleness.satellitePass) дни и може да не отразява днешното състояние.")
        }
        return sentences.joined(separator: " ")
    }
}
