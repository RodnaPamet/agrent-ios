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
        XCTAssertEqual(LunarWords.advice(read[1], .field, warned: false), ["Сеитба на фуражни треви и житни за зелена маса."],
                       "an unknown recommendation is no advice, not an error")
    }

    func testTheWordsAreTheWebs() async throws {
        let day = try await days(page)[0]
        XCTAssertEqual(LunarWords.dayType(day), "Листен ден")
        XCTAssertEqual(LunarWords.moon(day), "Растящ сърп, Риби")
        XCTAssertEqual(LunarWords.advice(day, .vegetable, warned: false),
                       ["Сеитба и разсаждане на зеле, салата, спанак и праз."])
        XCTAssertEqual(LunarWords.recommendations.count, 22, "the server's closed set (#3073 rules.ts)")
        let all = Array(LunarWords.recommendations.values) + Array(LunarWords.signs.values)
            + Array(LunarWords.phaseNames.values) + Array(LunarWords.dayTypes.values)
            + [LunarWords.traditionNotice, LunarWords.nothing, LunarWords.warning(2)]
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

    /// Owner, 2026-11-15: no sowing or planting on a frost or spray warning
    /// day; everything else stays.
    func testAWarningHoldsBackSowingOnly() async throws {
        let day = try await days(page)[2]
        XCTAssertTrue(LunarWords.heldBack(day))
        XCTAssertTrue(LunarWords.advice(day, .field, warned: true).isEmpty)
        XCTAssertTrue(LunarWords.advice(day, .vegetable, warned: true).isEmpty)
        XCTAssertEqual(LunarWords.advice(day, .perennial, warned: true), ["Бране на плодове за съхранение."],
                       "harvesting is not sowing")
        XCTAssertEqual(LunarWords.advice(day, .perennial, warned: false).count, 2, "positive control")
        XCTAssertEqual(LunarWords.warning(1), "Предупреждение за слана или пръскане в 1 блок. Сеитбата не се препоръчва.")
        XCTAssertEqual(LunarWarnings(blocksByDay: ["2026-03-23": 2]).blocks(on: "2026-03-23"), 2)
        XCTAssertEqual(LunarWarnings().blocks(on: "2026-03-23"), 0)
    }
}
