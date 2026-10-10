import XCTest
@testable import Agrent

/// The Дневник's filter (#252): type, crop, block and period, sent to the
/// journal route in its own names (`JournalQuerySchema`). NOTHING HERE ASKS THE
/// SERVER: the query, the day's edges and the options are decided above the
/// wire, and that is where they are pinned.
final class JournalFilterTests: XCTestCase {

    private var sofia: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }()

    /// 9 October 2026, 15:00 in Sofia (EEST, UTC+3).
    private let now = BgDate.parseInstant("2026-10-09T12:00:00.000Z")!

    private func day(_ iso: String) -> Date {
        // Noon UTC, so the day is the same one in any zone a test host has.
        BgDate.parseInstant(iso + "T12:00:00.000Z")!
    }

    private func path(_ filter: JournalFilter, cursor: String? = nil) -> String {
        JournalAPI.path(filter: filter, cursor: cursor, now: now, calendar: sofia)
    }

    // MARK: - The query

    /// No filter is the path the list always asked for: the cache key and
    /// the fixture key are this string.
    func testNoFilterIsThePathTheListAlwaysAskedFor() {
        let unfiltered = path(JournalFilter(now: now, calendar: sofia))
        XCTAssertTrue(unfiltered.hasSuffix("/journal?limit=50"), unfiltered)
        XCTAssertEqual(unfiltered, JournalAPI.listPath)
        XCTAssertFalse(JournalFilter().isActive)
    }

    func testEachFacetIsSentInTheRoutesOwnName() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.type = .inputApplication
        filter.crop = .init(label: "Пшеница", values: ["Wheat"])
        filter.block = .init(id: "loc_1", name: "Северен")
        let sent = path(filter)
        XCTAssertTrue(sent.contains("&type=INPUT_APPLICATION"), sent)
        XCTAssertTrue(sent.contains("&crop=Wheat"), sent)
        XCTAssertTrue(sent.contains("&locationId=loc_1"), sent)
        XCTAssertFalse(sent.contains("occurred"), "no period was chosen: \(sent)")
        XCTAssertTrue(filter.isActive)
    }

    /// Every spelling as ONE comma-separated value, which the route splits.
    /// The comma is encoded, and the server decodes it before the split.
    func testACropsSpellingsTravelAsOneCommaSeparatedValue() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.crop = .init(label: "Пшеница", values: ["Wheat", "wheat"])
        XCTAssertTrue(path(filter).contains("&crop=Wheat%2Cwheat"), path(filter))
    }

    /// A block id and a crop are values, never syntax: an `&` in either
    /// cannot add a parameter.
    func testAValueCannotForgeAParameter() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.block = .init(id: "loc&limit=9999", name: "x")
        let sent = path(filter)
        XCTAssertEqual(sent.components(separatedBy: "limit=").count - 1, 1, sent)
        XCTAssertTrue(sent.contains("locationId=loc%26limit%3D9999"), sent)
    }

    /// Page two asks the same question as page one.
    func testACursorKeepsTheFilter() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.type = .harvest
        let next = path(filter, cursor: "a+b")
        XCTAssertTrue(next.contains("&type=HARVEST"), next)
        XCTAssertTrue(next.hasSuffix("&cursor=a%2Bb"), next)
    }

    // MARK: - The day's edges

    /// «1 to 9 October» in Sofia is 30 September 21:00 UTC to the last
    /// millisecond of 9 October, 20:59:59.999 UTC. A bare `2026-10-09` would
    /// be UTC midnight to the server's `new Date`, and would drop the 9th.
    func testAChosenRangeRunsFromTheFirstDaysStartToTheLastDaysEnd() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.period = .custom
        filter.customFrom = day("2026-10-01")
        filter.customTo = day("2026-10-09")
        let sent = path(filter)
        XCTAssertTrue(sent.contains("&occurredFrom=2026-09-30T21%3A00%3A00.000Z"), sent)
        XCTAssertTrue(sent.contains("&occurredTo=2026-10-09T20%3A59%3A59.999Z"), sent)
    }

    /// The sheet keeps «От» before «До»; the filter orders them anyway.
    func testAReversedRangeIsOrdered() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.period = .custom
        filter.customFrom = day("2026-10-09")
        filter.customTo = day("2026-10-01")
        let (from, to) = filter.bounds(now: now, calendar: sofia)
        XCTAssertEqual(from.map(BgDate.isoInstant), "2026-09-30T21:00:00.000Z")
        XCTAssertEqual(to.map(BgDate.isoInstant), "2026-10-09T20:59:59.999Z")
    }

    /// Thirty days counting today: 10 September to the end of 9 October.
    func testTheLastThirtyDaysCountToday() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.period = .last30Days
        let (from, to) = filter.bounds(now: now, calendar: sofia)
        XCTAssertEqual(from.map(BgDate.isoInstant), "2026-09-09T21:00:00.000Z")
        XCTAssertEqual(to.map(BgDate.isoInstant), "2026-10-09T20:59:59.999Z")
    }

    /// The whole calendar year, in winter time at both ends (UTC+2).
    func testThisYearIsTheCalendarYear() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.period = .thisYear
        let (from, to) = filter.bounds(now: now, calendar: sofia)
        XCTAssertEqual(from.map(BgDate.isoInstant), "2025-12-31T22:00:00.000Z")
        XCTAssertEqual(to.map(BgDate.isoInstant), "2026-12-31T21:59:59.999Z")
    }

    /// `ISO8601FormatStyle` truncates, and `Double` holds `…59.999` as
    /// `…59.998999…`, so it wrote `.998`. `isoInstant` rounds to the
    /// millisecond and writes the digits itself.
    func testAnInstantIsWrittenToTheMillisecondItHolds() {
        let lastMoment = BgDate.parseInstant("2026-10-09T21:00:00.000Z")!.addingTimeInterval(-0.001)
        XCTAssertEqual(BgDate.isoInstant(lastMoment), "2026-10-09T20:59:59.999Z")
        XCTAssertEqual(BgDate.isoInstant(BgDate.parseInstant("2026-10-09T08:07:06.042Z")!),
                       "2026-10-09T08:07:06.042Z")
        XCTAssertEqual(BgDate.isoInstant(BgDate.parseInstant("1969-12-31T23:59:59.250Z")!),
                       "1969-12-31T23:59:59.250Z")
    }

    func testAnyDateSendsNoBounds() {
        let (from, to) = JournalFilter(now: now, calendar: sofia).bounds(now: now, calendar: sofia)
        XCTAssertNil(from)
        XCTAssertNil(to)
    }

    // MARK: - An entry the phone just wrote

    private func entry(_ type: LogEntryType, at iso: String?) -> LogEntry {
        LogEntry(id: "e1", type: type, status: .done, title: "t", notes: nil,
                 occurredAt: iso.flatMap(BgDate.parseInstant), version: 0)
    }

    func testEverythingIsAdmittedWithNoFilter() {
        let filter = JournalFilter(now: now, calendar: sofia)
        XCTAssertTrue(filter.admits(entry(.activity, at: nil), now: now, calendar: sofia))
    }

    /// The phone writes free-hand entries: no operation line, no block link.
    /// The server's crop and block filters can never return one.
    func testACropOrABlockRulesOutAFreeHandEntry() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.crop = .init(label: "Пшеница", values: ["Wheat"])
        XCTAssertFalse(filter.admits(entry(.activity, at: "2026-10-09T08:00:00.000Z"), now: now, calendar: sofia))
        filter.crop = nil
        filter.block = .init(id: "loc_1", name: "Северен")
        XCTAssertFalse(filter.admits(entry(.activity, at: "2026-10-09T08:00:00.000Z"), now: now, calendar: sofia))
    }

    /// An entry linked to the filtered block on «Нов запис» (#254) is one
    /// the server returns through `LogLocation`, so it stays on the list.
    func testABlockFilterAdmitsAnEntryLinkedToThatBlock() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.block = .init(id: "loc_1", name: "Северен")
        let written = entry(.activity, at: "2026-10-09T08:00:00.000Z")
        XCTAssertTrue(filter.admits(written, linkedTo: ["loc_2", "loc_1"], now: now, calendar: sofia))
        XCTAssertFalse(filter.admits(written, linkedTo: ["loc_2"], now: now, calendar: sofia))
        // A crop still rules it out: a link is not an operation line.
        filter.crop = .init(label: "Пшеница", values: ["Wheat"])
        XCTAssertFalse(filter.admits(written, linkedTo: ["loc_1"], now: now, calendar: sofia))
    }

    func testTypeAndPeriodAreCheckedAsTheServerChecksThem() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.type = .seeding
        filter.period = .last30Days
        XCTAssertTrue(filter.admits(entry(.seeding, at: "2026-10-09T08:00:00.000Z"), now: now, calendar: sofia))
        XCTAssertFalse(filter.admits(entry(.harvest, at: "2026-10-09T08:00:00.000Z"), now: now, calendar: sofia))
        XCTAssertFalse(filter.admits(entry(.seeding, at: "2026-08-01T08:00:00.000Z"), now: now, calendar: sofia))
        // An entry with no date is outside any period.
        XCTAssertFalse(filter.admits(entry(.seeding, at: nil), now: now, calendar: sofia))
    }

    // MARK: - The crops on offer

    /// Two spellings, one name, both sent: the server matches exactly.
    func testSpellingsOfOneCropAreOneChoiceCarryingBoth() {
        let crops = JournalFilter.Crop.options(from: ["Wheat", "wheat", "Wheat", "Maize", nil, ""])
        XCTAssertEqual(crops, [
            .init(label: "Пшеница", values: ["Wheat", "wheat"]),
            .init(label: "Царевица", values: ["Maize"]),
        ])
    }

    /// A crop no catalogue knows is offered as written, as everywhere a
    /// parcel's crop is shown (`CommodityName.freeText`).
    func testAnUncataloguedCropIsOfferedAsWritten() {
        XCTAssertEqual(JournalFilter.Crop.options(from: ["Grass"]).map(\.label), ["Grass"])
    }

    /// The route splits on commas and trims each part, so these could never
    /// match. Offering one would ask the server for something else.
    func testSpellingsTheRouteCannotCarryAreNotOffered() {
        let crops = JournalFilter.Crop.options(from: ["Grass, ley", " Wheat", String(repeating: "x", count: 201)])
        XCTAssertEqual(crops, [])
        // Positive control: the same words, sendable, are offered.
        XCTAssertEqual(JournalFilter.Crop.options(from: ["Grass ley", "Wheat"]).count, 2)
    }

    func testCropsAreInBulgarianOrder() {
        let labels = JournalFilter.Crop.options(from: ["Sunflower", "Barley", "Wheat", "Maize"]).map(\.label)
        XCTAssertEqual(labels, ["Ечемик", "Пшеница", "Слънчоглед", "Царевица"])
    }

    // MARK: - The blocks on offer

    /// A block is a FIELD location; a bin or a store is not one. A location
    /// whose `kind` is absent is a field, the server's default.
    func testOnlyFieldsAreBlocks() async throws {
        let json = #"""
        [{"id":"l1","name":"Север","status":"ACTIVE","kind":"FIELD"},
         {"id":"l2","name":"Юг","status":"ACTIVE"},
         {"id":"l3","name":"Силоз","status":"ACTIVE","kind":"BIN"},
         {"id":"l4","name":"Склад","status":"ACTIVE","kind":"STORAGE"}]
        """#
        let locations = try await LocationsAPI.decodeList(from: Data(json.utf8))
        XCTAssertEqual(JournalFilter.Block.options(from: locations).map(\.id), ["l1", "l2"])
    }

    /// A choice the farm no longer offers stays chosen and on the list, so
    /// the picker never shows nothing while the filter still applies it.
    func testAChoiceNoLongerOfferedIsKept() {
        let gone = JournalFilter.Block(id: "old", name: "Стар")
        let here = JournalFilter.Block(id: "l1", name: "Север")
        XCTAssertEqual(JournalFilterSheet.keeping(gone, in: [here]), [gone, here])
        XCTAssertEqual(JournalFilterSheet.keeping(here, in: [here]), [here])
        XCTAssertEqual(JournalFilterSheet.keeping(nil, in: [here]), [here])
    }

    // MARK: - Said back

    func testTheSummaryNamesEachFacet() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.type = .seeding
        filter.crop = .init(label: "Пшеница", values: ["Wheat"])
        filter.block = .init(id: "l1", name: "Север")
        filter.period = .thisYear
        XCTAssertEqual(filter.facts(now: now, calendar: sofia), [
            "Тип: Сеитба", "Култура: Пшеница", "Блок: Север", "Период: Тази година",
        ])
    }

    func testAChosenPeriodIsSaidAsItsDays() {
        var filter = JournalFilter(now: now, calendar: sofia)
        filter.period = .custom
        filter.customFrom = day("2026-10-01")
        filter.customTo = day("2026-10-09")
        XCTAssertEqual(filter.periodText(now: now, calendar: sofia), "1 октомври – 9 октомври")
        filter.customFrom = day("2026-10-09")
        XCTAssertEqual(filter.periodText(now: now, calendar: sofia), "9 октомври")
        // Another year's day carries its year. ICU joins the year and «г.»
        // with U+202F, a narrow no-break space (see `BgDateTests`).
        filter.customFrom = day("2025-11-03")
        XCTAssertEqual(filter.periodText(now: now, calendar: sofia), "3 ноември 2025\u{202F}г. – 9 октомври")
    }

    // MARK: - The store

    /// The store's two promises, read from its source because unit tests have
    /// no URLProtocol seam: a filtered page is never cached, and an answer to
    /// a question no longer asked is dropped.
    func testTheStoreCachesOnlyTheUnfilteredPageAndDropsStaleAnswers() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Agrent/Journal/JournalStore.swift"),
            encoding: .utf8)
        let filtered = try XCTUnwrap(source.range(of: "if asked.isActive {"))
        let cached = try XCTUnwrap(source.range(of: "CachedResource.loadShowingCacheFirst(path)"))
        let unfiltered = try XCTUnwrap(source.range(of: "} else {", range: filtered.upperBound..<source.endIndex))
        XCTAssertTrue(cached.lowerBound > unfiltered.lowerBound,
                      "the cache is read and written only on the unfiltered branch")
        XCTAssertEqual(source.components(separatedBy: "filter == asked").count - 1, 4,
                       "first page, cached first page, next page and its failure each check the filter")
    }
}
