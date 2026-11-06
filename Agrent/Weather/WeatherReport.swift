import Foundation

/// A block's weather, as the «Времето» sheet shows it (#551, owner
/// 2026-11-06): the app's own values, not WeatherKit's types, so the sheet
/// can be drawn from a fixture and tested without asking Apple.
///
/// ── Why wind and pressure lead ──
///
/// The owner asked for "the winds and the cyclones dynamics". WeatherKit has
/// no map and no storm tracks, so a passing low shows the way a barometer
/// shows it: pressure falling over the coming hours, and the wind backing
/// and rising with it. So the sheet puts the wind (m/s, the unit a sprayer's
/// label uses), the pressure and where it is heading first.
struct WeatherReport: Equatable, Sendable {
    struct Now: Equatable, Sendable {
        let temperatureC: Double
        let windMS: Double
        let gustMS: Double?
        /// Where the wind comes FROM, degrees clockwise from north.
        let windFromDegrees: Double
        let pressureHPa: Double
        let pressureTrend: PressureTrend
        /// 0…1.
        let humidity: Double
    }

    struct Hour: Equatable, Sendable, Identifiable {
        let date: Date
        let windMS: Double
        let gustMS: Double?
        let windFromDegrees: Double
        let pressureHPa: Double
        /// 0…1.
        let precipitationChance: Double
        var id: Date { date }
    }

    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        let highC: Double
        let lowC: Double
        let windMS: Double
        let windFromDegrees: Double
        /// 0…1.
        let precipitationChance: Double
        var id: Date { date }
    }

    struct Alert: Equatable, Sendable, Identifiable {
        let summary: String
        let severity: String
        let source: String
        let detailsURL: URL?
        var id: String { summary + source }
    }

    enum PressureTrend: Equatable, Sendable { case rising, falling, steady, unknown }

    /// What the service requires shown beside its data: its mark and a link
    /// to its sources.
    struct Attribution: Equatable, Sendable {
        let markLightURL: URL?
        let markDarkURL: URL?
        let legalPageURL: URL?
        let serviceName: String
    }

    let now: Now
    let hours: [Hour]
    let days: [Day]
    let alerts: [Alert]
    let attribution: Attribution?
}

/// The sheet's words and numbers, in Bulgarian, pure, so tests pin them.
enum WeatherWords {
    /// «СЗ», where the wind comes from, in eight points: С, СИ, И, ЮИ, Ю,
    /// ЮЗ, З, СЗ. WeatherKit's own compass is English («NW»).
    static func compass(_ degrees: Double) -> String {
        let points = ["С", "СИ", "И", "ЮИ", "Ю", "ЮЗ", "З", "СЗ"]
        let normalised = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalised + 22.5) / 45) % 8]
    }

    /// The same, said: «северозапад».
    static func compassSpoken(_ degrees: Double) -> String {
        let names = ["север", "североизток", "изток", "югоизток", "юг", "югозапад", "запад", "северозапад"]
        let normalised = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalised + 22.5) / 45) % 8]
    }

    /// «4,2 м/с».
    static func speed(_ ms: Double) -> String { "\(number(ms, places: 1)) м/с" }

    /// «1013 hPa».
    static func pressure(_ hPa: Double) -> String { "\(number(hPa, places: 0)) hPa" }

    /// «12°».
    static func temperature(_ c: Double) -> String { "\(number(c, places: 0))°" }

    /// «40 %».
    static func percent(_ fraction: Double) -> String { "\(number(fraction * 100, places: 0)) %" }

    /// Where the pressure is heading, and what that usually means here.
    static func trend(_ trend: WeatherReport.PressureTrend) -> String? {
        switch trend {
        case .falling: "Налягането пада — обикновено идва ниско налягане (циклон): повече вятър, облаци и валежи."
        case .rising: "Налягането расте — обикновено идва високо налягане (антициклон): по-тихо и по-сухо време."
        case .steady: "Налягането е стабилно."
        case .unknown: nil
        }
    }

    /// The change over the next `hours`: «−6 hPa за 24 ч», nil when the
    /// forecast is shorter.
    static func pressureChange(_ hours: [WeatherReport.Hour], over span: Int = 24) -> Double? {
        guard let first = hours.first, hours.count > span else { return nil }
        return hours[span].pressureHPa - first.pressureHPa
    }

    /// «−6 hPa за 24 ч» / «+3 hPa за 24 ч».
    static func changeText(_ change: Double, over span: Int = 24) -> String {
        let sign = change > 0 ? "+" : change < 0 ? "−" : "±"
        return "\(sign)\(number(abs(change), places: 0)) hPa за \(span) ч"
    }

    /// A fall this fast is a deepening low, said plainly: 3 hPa in three
    /// hours is the meteorologists' «rapid», and 6 in 24 already brings a
    /// windy change.
    static func isSharpFall(_ change: Double) -> Bool { change <= -6 }

    /// An alert's own words when they are Bulgarian, the owner's rule for
    /// any prose from elsewhere (2026-10-13); a plain title when they are
    /// not, with its source and link beside it.
    static func alertTitle(_ summary: String) -> String {
        var cyrillic = 0, latin = 0
        for scalar in summary.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        return cyrillic > latin ? summary : "Предупреждение за времето"
    }

    /// Bulgarian digits: the comma, and no grouping, so «1013 hPa» does not
    /// read «1 013».
    static func number(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...places)).grouping(.never).locale(BgDate.locale))
    }
}
