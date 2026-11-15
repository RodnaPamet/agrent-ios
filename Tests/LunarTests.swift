import XCTest
@testable import Agrent

/// «Лунен календар» (#611) against agri-saas #3073's `GET /api/lunar`.
/// Read-only; the days are synthetic.
final class LunarTests: XCTestCase {

    private let calendar = FarmRecordAPI.farmCalendar

    private func days(_ json: String) async throws -> [LunarDay] {
        try await APIClient.shared.decode(Data(json.utf8), as: LunarPage.self).days
    }

    private let page = """
    {"days":[
      {"date":"2026-03-21","phase":"waxing","phaseName":"waxingCrescent","illumination":0.12,"sign":"pisces",
       "element":"water","dayType":"leaf","transitions":[],
       "recommendations":{"field":["sowForageGrass"],"vegetable":["sowLeafyVeg"],"perennial":["leafFeeding","grafting"]}},
      {"date":"2026-03-22","phase":"waxing","phaseName":"waxingCrescent","illumination":0.2,"sign":"pisces",
       "element":"water","dayType":"leaf","transitions":[{"at":"2026-03-22T12:20:00.000Z","toSign":"aries","toDayType":"fruit"}],
       "recommendations":{"field":["sowForageGrass","plowByStarlight"],"vegetable":[],"perennial":["leafFeeding"]}},
      {"date":"2026-03-23","phase":"waxing","phaseName":"firstQuarter","illumination":0.3,"sign":"aries",
       "element":"fire","dayType":"fruit","transitions":[{"at":"2026-03-23T03:10:00.000Z","toSign":"aries","toDayType":"fruit"}],
       "recommendations":{"field":["sowCerealGrain"],"vegetable":["sowFruitingVeg"],"perennial":["plantTreesVines","harvestForStorage"]}},
      {"date":"2026-03-24","phase":"waxing","phaseName":"halfMoonish","illumination":0.4,"sign":"ophiuchus",
       "element":"fire","dayType":"meteor","transitions":[],"recommendations":{}}
    ],"timeZone":"Europe/Sofia","maxDays":62}
    """

    func testThePathIsOneMonthInTheFarmsZone() throws {
        let inside = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 23)))
        let month = LunarAPI.month(containing: inside, calendar: calendar)
        XCTAssertEqual(LunarAPI.path(from: month.from, to: month.to, calendar: calendar),
                       "/api/lunar?from=2026-02-01&to=2026-02-28")
        let days = calendar.dateComponents([.day], from: month.from, to: month.to).day ?? 0
        XCTAssertLessThan(days + 1, LunarAPI.maxDays)
    }

    /// A value the phone does not know yet shows as nothing; the page still reads.
    func testUnknownValuesDoNotLoseThePage() async throws {
        let read = try await days(page)
        XCTAssertEqual(read.count, 4)
        let odd = read[3]
        XCTAssertEqual(LunarWords.dayType(odd), "")
        XCTAssertEqual(LunarWords.moon(odd), "", "neither the phase nor the sign is known")
        for group in LunarWords.Group.allCases {
            XCTAssertTrue(LunarWords.advice(odd, group, warned: false).isEmpty)
        }
        XCTAssertEqual(LunarWords.advice(read[1], .field, warned: false).map(\.text), ["Сеитба на фуражни треви и житни за зелена маса."],
                       "an unknown recommendation is no advice, not an error")
    }

    func testTheWordsAreTheWebs() async throws {
        let day = try await days(page)[0]
        XCTAssertEqual(LunarWords.dayType(day), "Листен ден")
        XCTAssertEqual(LunarWords.moon(day), "Растящ сърп, Риби")
        XCTAssertEqual(LunarWords.advice(day, .vegetable, warned: false).map(\.text),
                       ["Сеитба и разсаждане на зеле, салата, спанак и праз."])
        XCTAssertEqual(LunarWords.recommendations.count, 22, "the server's closed set (#3073 rules.ts)")
        let all = Array(LunarWords.recommendations.values) + Array(LunarWords.signs.values)
            + Array(LunarWords.phaseNames.values) + Array(LunarWords.dayTypes.values)
            + [LunarWords.traditionNotice, LunarWords.nothing]
        for text in all {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }

    /// The sign changes at 14:20 Sofia (12:20 UTC in March), after noon: the
    /// day reads as noon's type until then.
    func testASplitDaySaysWhenItTurns() async throws {
        let read = try await days(page)
        XCTAssertEqual(LunarWords.dayType(read[1], calendar: calendar), "Листен ден до 14:20, после плоден ден")
        // A change before noon: the noon reading is already the new type.
        XCTAssertEqual(LunarWords.dayType(read[2], calendar: calendar), "Плоден ден от 5:10")
    }

    /// Owner, 2026-11-15: on a frost or spray warning day the sowing and
    /// planting lines stay, STRUCK; everything else is untouched.
    func testAWarningStrikesSowingOnly() async throws {
        let day = try await days(page)[2]
        XCTAssertTrue(LunarWords.heldBack(day))
        XCTAssertEqual(LunarWords.advice(day, .field, warned: true),
                       [.init(text: "Сеитба на житни за зърно, царевица и фасул.", struck: true)])
        XCTAssertEqual(LunarWords.advice(day, .perennial, warned: true), [
            .init(text: "Садене на плодни дървета и лози.", struck: true),
            .init(text: "Бране на плодове за съхранение.", struck: false),
        ], "harvesting is not sowing")
        XCTAssertFalse(LunarWords.advice(day, .field, warned: false)[0].struck, "positive control")
    }

    func testTheWarningsAreWordedPerKind() {
        let warnings = LunarWarnings(frostBlocks: ["2026-03-23": 2], sprayBlocks: ["2026-03-23": 1, "2026-03-24": 3],
                                     horizon: "2026-03-24")
        XCTAssertEqual(LunarWords.warnings(warnings, on: "2026-03-23"),
                       ["Предупреждение за слана в 2 блока", "Неподходящ ден за пръскане в 1 блок"])
        XCTAssertEqual(LunarWords.warnings(warnings, on: "2026-03-24"), ["Неподходящ ден за пръскане в 3 блока"])
        XCTAssertTrue(LunarWords.warnings(warnings, on: "2026-03-25").isEmpty)
        XCTAssertTrue(warnings.warned(on: "2026-03-24"))
        XCTAssertFalse(warnings.warned(on: "2026-03-25"))
        let end = try? XCTUnwrap(BgDate.parseISODay("2026-03-24"))
        XCTAssertEqual(end.map(LunarWords.horizon), "Прогноза за слана и пръскане има само до 24 март.")
        for text in LunarWords.warnings(warnings, on: "2026-03-23") + [LunarWords.struckSpoken] {
            XCTAssertNil(text.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), text)
        }
    }

    // MARK: - The farm's warnings (agri-saas #3077)

    private func signals(_ json: String) async throws -> LunarWarnings {
        AgroSignalsAPI.warnings(try await APIClient.shared.decode(Data(json.utf8), as: AgroSignalsAPI.Page.self))
    }

    /// Blocks per day per kind, each block once; spray's presence is the
    /// warning; disease is not about sowing; an unknown kind still warns.
    func testSignalsBecomeBlocksPerDay() async throws {
        let warnings = try await signals("""
        {"signals":[
          {"locationId":"b1","kind":"FROST_RISK","level":"FROST","signalDate":"2026-11-16"},
          {"locationId":"b2","kind":"FROST_RISK","level":"FROST","signalDate":"2026-11-16"},
          {"locationId":"b2","kind":"FROST_RISK","level":"FROST","signalDate":"2026-11-16"},
          {"locationId":"b1","kind":"SPRAY_WINDOW","signalDate":"2026-11-15"},
          {"locationId":"b3","kind":"DISEASE_RISK","signalDate":"2026-11-15"},
          {"locationId":"b4","kind":"HAIL_RISK","signalDate":"2026-11-17"}
        ],"horizon":"2026-11-17","frostThresholdC":2,"truncated":false}
        """)
        XCTAssertTrue(warnings.known)
        XCTAssertEqual(warnings.frost(on: "2026-11-16"), 2, "each block once")
        XCTAssertEqual(warnings.spray(on: "2026-11-15"), 1)
        XCTAssertTrue(warnings.warned(on: "2026-11-15"))
        XCTAssertTrue(warnings.warned(on: "2026-11-17"), "an unknown kind is a warning, never dropped")
        XCTAssertEqual(LunarWords.warnings(warnings, on: "2026-11-17"), ["Предупреждение в 1 блок"])
        XCTAssertFalse(warnings.warned(on: "2026-11-18"))
        XCTAssertEqual(warnings.horizon, "2026-11-17")
    }

    func testTheNotesSayWhatTheWarningsCannotSay() async throws {
        let full = try await signals(#"{"signals":[],"horizon":"2026-11-17","frostThresholdC":2,"truncated":true}"#)
        let notes = LunarWords.warningNotes(full, farmOpen: true)
        XCTAssertEqual(notes[0], "Прогноза за слана и пръскане има само до 17 ноември.")
        XCTAssertTrue(notes[1].contains("2 °C"), notes[1])
        XCTAssertTrue(notes[2].hasPrefix("Списъкът с предупреждения е непълен."), notes[2])

        let noWeather = try await signals(#"{"signals":[],"horizon":null,"frostThresholdC":2,"truncated":false}"#)
        XCTAssertTrue(LunarWords.warningNotes(noWeather, farmOpen: true)[0].hasPrefix("Няма прогноза"))
        XCTAssertTrue(LunarWords.warningNotes(LunarWarnings(), farmOpen: true)[0].contains("не можаха да се заредят"),
                      "a failed read is unknown, never \"no warning\"")
        XCTAssertTrue(LunarWords.warningNotes(LunarWarnings(), farmOpen: false)[0].contains("когато е избрано стопанство"))
        for note in notes + LunarWords.warningNotes(LunarWarnings(), farmOpen: true) {
            XCTAssertNil(note.range(of: "[ыэё]|ь(?!о)", options: .regularExpression), note)
        }
    }

    func testTheSignalsPathIsTheFarmsAndTheMonths() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let month = LunarAPI.month(containing: day, calendar: calendar)
        let path = AgroSignalsAPI.path(from: month.from, to: month.to, calendar: calendar)
        XCTAssertTrue(path.hasSuffix("/agro/signals?from=2026-11-01&to=2026-11-30"), path)
    }
}
