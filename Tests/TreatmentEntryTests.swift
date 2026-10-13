import MapKit
import XCTest
@testable import Agrent

/// «Ново мероприятие» (agrent-ios#293): the ДНЕВНИК's fields, all required;
/// the crop's parcels across blocks; the map's tap; and the record that is
/// saved. Synthetic fixtures throughout — no real field, name or outline.
final class TreatmentEntryTests: XCTestCase {

    private let today = BgDate.parseInstant("2026-10-13T09:00:00.000Z")!
    private let kgPerDca = Agrent.Unit(id: "u-kg", key: "kg_dca", name: "килограм на декар", symbol: "кг/дка", measure: "RATE")
    private let mlPerDca = Agrent.Unit(id: "u-ml", key: "ml_dca", name: "милилитър на декар", symbol: "мл/дка", measure: "RATE")

    private func item(_ name: String, category: String = "PESTICIDE", quarantine: Int? = nil,
                      unit: Agrent.Unit? = nil) -> InputItem {
        var item = InputItem(id: "i-\(name)", name: name, category: category, defaultUnit: unit,
                             createdByUserId: "u1")
        item.quarantinePeriodDays = quarantine
        return item
    }

    // MARK: - Step one: every field the ДНЕВНИК prints

    func testAnEmptySprayAsksForEveryChemicalColumn() {
        let draft = TreatmentDraft(date: today)
        XCTAssertEqual(draft.problems(catalogue: [], now: today),
                       [.productMissing, .pestMissing, .doseMissing, .unitMissing, .quarantineMissing])
    }

    /// The fertiliser table has no pest, quarantine or machinery column.
    func testFertilisingAsksOnlyForItsOwnColumns() {
        var draft = TreatmentDraft(date: today)
        draft.kind = .fertilize
        XCTAssertEqual(draft.problems(catalogue: [], now: today), [.productMissing, .doseMissing, .unitMissing])
        draft.productText = "Амониева селитра"
        draft.doseText = "25"
        draft.doseUnit = kgPerDca
        XCTAssertEqual(draft.problems(catalogue: [], now: today), [])
    }

    func testACompleteSprayHasNoProblem() {
        var draft = TreatmentDraft(date: today)
        draft.productText = "Синтетичен инсектицид"
        draft.pestText = "Листни въшки"
        draft.doseText = "12,5"
        draft.doseUnit = mlPerDca
        draft.quarantineText = "14"
        let catalogue = [item("Синтетичен инсектицид", quarantine: 14)]
        XCTAssertEqual(draft.problems(catalogue: catalogue, now: today), [])
        XCTAssertEqual(draft.dose, Decimal(string: "12.5"), "a comma is a decimal separator")
    }

    /// Done work only (owner, 2026-10-13): a date after today is refused.
    func testATreatmentInTheFutureIsNotRecorded() {
        var draft = TreatmentDraft(date: today.addingTimeInterval(2 * 86_400))
        draft.kind = .fertilize
        draft.productText = "Тор"; draft.doseText = "1"; draft.doseUnit = kgPerDca
        XCTAssertEqual(draft.problems(catalogue: [], now: today), [.futureDate])
        XCTAssertFalse(TreatmentDraft.Problem.futureDate.text.isEmpty)
    }

    /// A plant protection product new to the farm needs its ЗЗР number; one
    /// the farm has carries its own.
    func testOnlyANewPesticideAsksForItsRegistration() {
        var draft = TreatmentDraft(date: today)
        draft.productText = "Нов препарат"
        XCTAssertTrue(draft.problems(catalogue: [], now: today).contains(.registrationMissing))
        draft.registrationText = "0123-ПРЗ"
        XCTAssertFalse(draft.problems(catalogue: [], now: today).contains(.registrationMissing))

        var known = TreatmentDraft(date: today)
        known.productText = "Познат препарат"
        let catalogue = [item("Познат препарат")]
        XCTAssertEqual(known.typed(in: catalogue), .existing(catalogue[0]), "precondition: matched")
        XCTAssertEqual(known.problems(catalogue: catalogue, now: today),
                       [.pestMissing, .doseMissing, .unitMissing, .quarantineMissing])
    }

    func testANonPositiveDoseIsRefused() {
        var draft = TreatmentDraft(date: today)
        draft.doseText = "0"
        XCTAssertTrue(draft.problems(catalogue: [], now: today).contains(.doseNotPositive))
        XCTAssertFalse(draft.problems(catalogue: [], now: today).contains(.doseMissing))
    }

    /// Every problem is said in a Bulgarian sentence.
    func testEveryProblemIsASentence() {
        let all: [TreatmentDraft.Problem] = [.futureDate, .productMissing, .product("Продуктът е образец."),
                                             .registrationMissing,
                                             .pestMissing, .doseMissing, .doseNotPositive, .unitMissing,
                                             .quarantineMissing]
        for problem in all {
            XCTAssertTrue(UserMessage.isBulgarianSentence(problem.text), problem.text)
            XCTAssertTrue(problem.text.hasSuffix("."), problem.text)
        }
    }

    // MARK: - The earliest harvest date and the prefill

    /// The ДНЕВНИК's own rule (`buildChemicalRows`): the date plus the
    /// quarantine period. Never for fertilising.
    func testTheEarliestHarvestIsTheDatePlusTheQuarantine() throws {
        // Noon UTC is 13 October on every phone from UTC−11 to UTC+11.
        var draft = TreatmentDraft(date: try XCTUnwrap(BgDate.parseInstant("2026-10-13T12:00:00.000Z")))
        draft.quarantineText = "21"
        let harvest = try XCTUnwrap(draft.earliestHarvest)
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: harvest)
        XCTAssertEqual([day.year, day.month, day.day], [2026, 11, 3], "13 October + 21 days")
        draft.quarantineText = ""
        XCTAssertNil(draft.earliestHarvest)
        draft.quarantineText = "21"
        draft.kind = .fertilize
        XCTAssertNil(draft.earliestHarvest)
    }

    /// The product's own quarantine period and unit fill empty fields, and
    /// never what the person typed. The unit is `/units`' own row.
    func testAKnownProductPrefillsOnlyWhatIsEmpty() {
        let product = item("Познат препарат", quarantine: 30,
                           unit: Agrent.Unit(id: "u-ml", key: "ml_dca", name: nil, symbol: "мл/дка", measure: nil))
        var draft = TreatmentDraft(date: today)
        draft.prefill(from: .existing(product), units: [kgPerDca, mlPerDca])
        XCTAssertEqual(draft.quarantineText, "30")
        XCTAssertEqual(draft.doseUnit, mlPerDca, "the /items copy has no name and would not match a tag")

        var typed = TreatmentDraft(date: today)
        typed.quarantineText = "7"
        typed.doseUnit = kgPerDca
        typed.prefill(from: .existing(product), units: [kgPerDca, mlPerDca])
        XCTAssertEqual(typed.quarantineText, "7", "the prefill overwrote a typed period")
        XCTAssertEqual(typed.doseUnit, kgPerDca)

        var new = TreatmentDraft(date: today)
        new.prefill(from: .new, units: [kgPerDca])
        XCTAssertEqual(new.quarantineText, "")
    }

    /// A prefill the person has not touched follows the product: «Карате» on
    /// the way to «Карате Зеон 5 CS» must not leave the first one's period —
    /// a wrong earliest harvest date on a legal register — and a name that
    /// stops matching takes it away again.
    func testAnUntouchedPrefillFollowsTheProduct() {
        let first = item("Първи", quarantine: 14, unit: Agrent.Unit(id: "u-ml", key: "", name: nil, symbol: "", measure: nil))
        let second = item("Втори", quarantine: 30, unit: Agrent.Unit(id: "u-kg", key: "", name: nil, symbol: "", measure: nil))
        let units = [kgPerDca, mlPerDca]
        var draft = TreatmentDraft(date: today)
        draft.prefill(from: .existing(first), units: units)
        XCTAssertEqual(draft.quarantineText, "14")
        draft.prefill(from: .existing(second), units: units)
        XCTAssertEqual(draft.quarantineText, "30", "the first product's period stayed")
        XCTAssertEqual(draft.doseUnit, kgPerDca, "the first product's unit stayed")
        draft.prefill(from: .new, units: units)
        XCTAssertEqual(draft.quarantineText, "", "a new product inherited the last one's period")
        XCTAssertNil(draft.doseUnit)

        // Once typed, the person's: no later product replaces it.
        draft.prefill(from: .existing(first), units: units)
        draft.quarantineText = "21"
        draft.prefill(from: .existing(second), units: units)
        XCTAssertEqual(draft.quarantineText, "21")
    }

    /// The same key for the same entry across retries; a new one once what
    /// was entered changes — compared on the draft and the SET of parcels,
    /// never on order.
    func testTheSaveKeyFollowsWhatWasEntered() {
        var attempt = TreatmentAttempt()
        var draft = TreatmentDraft(date: today)
        draft.productText = "А"
        let first = attempt.key(for: draft, parcels: ["p1", "p2"])
        XCTAssertEqual(attempt.key(for: draft, parcels: ["p2", "p1"]), first, "a retry minted a new key")
        draft.doseText = "5"
        let second = attempt.key(for: draft, parcels: ["p1", "p2"])
        XCTAssertNotEqual(second, first, "a corrected entry kept the old key")
        XCTAssertNotEqual(attempt.key(for: draft, parcels: ["p1"]), second, "a different set of parcels kept the key")
    }

    /// The registration `/items` already sends is read — and one of the wrong
    /// type costs that field, never the catalogue.
    /// The original keys keep their strictness: a catalogue row without a
    /// name is still refused, as before the lenient two were added.
    func testTheCataloguesOriginalKeysAreStillStrict() {
        let noName = #"[{"id":"a","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u"}]"#
        XCTAssertThrowsError(try JSONDecoder().decode([InputItem].self, from: Data(noName.utf8)))
        let numericID = #"[{"id":5,"name":"А","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u"}]"#
        XCTAssertThrowsError(try JSONDecoder().decode([InputItem].self, from: Data(numericID.utf8)))
    }

    func testTheCatalogueCarriesTheRegistrationLeniently() throws {
        let json = """
        [{"id":"a","name":"А","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u",
          "pppRegistrationNo":"0042","quarantinePeriodDays":14},
         {"id":"b","name":"Б","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u",
          "pppRegistrationNo":7,"quarantinePeriodDays":"много"}]
        """
        let items = try JSONDecoder().decode([InputItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 2, "a badly typed registration cost the catalogue")
        XCTAssertEqual(items[0].quarantinePeriodDays, 14)
        XCTAssertEqual(items[0].pppRegistrationNo, "0042")
        XCTAssertNil(items[1].quarantinePeriodDays)
        XCTAssertNil(items[1].pppRegistrationNo)
    }

    // MARK: - Step two: the crop's parcels across blocks

    private func block(_ id: String, _ name: String) throws -> Location {
        try JSONDecoder().decode(Location.self, from: Data("""
        {"id":"\(id)","name":"\(name)","description":null,"status":"ACTIVE","capacityTonnes":null}
        """.utf8))
    }

    /// A synthetic square, `side` degrees wide, south-west corner at (lon, lat).
    private func square(lon: Double, lat: Double, side: Double) -> ParcelGeometry {
        let ring = [[lon, lat], [lon + side, lat], [lon + side, lat + side], [lon, lat + side], [lon, lat]]
        return ParcelGeometry(type: "MultiPolygon", coordinates: [[ring]])
    }

    private func parcel(_ id: String, _ name: String, crop: String?, ha: Double?,
                        geometry: ParcelGeometry? = nil) -> Parcel {
        Parcel(id: id, name: name, cropType: crop, areaHa: ha, geometry: geometry,
               soilType: nil, cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
    }

    /// One crop is one crop wherever it grows and however it is spelt:
    /// parcels from two blocks under one Bulgarian name, by block and then by
    /// number; a parcel with no crop is not offered.
    func testACropGathersItsParcelsAcrossBlocks() throws {
        let north = try block("b1", "Блок Север")
        let south = try block("b2", "Блок Юг")
        let crops = TreatmentPlace.crops([
            (south, [parcel("s10", "10", crop: "Wheat", ha: 2), parcel("s2", "2", crop: "wheat", ha: 1)]),
            (north, [parcel("n1", "1", crop: "Wheat", ha: 3), parcel("n9", "9", crop: nil, ha: 1),
                     parcel("n5", "5", crop: "  ", ha: 1), parcel("n3", "3", crop: "Sunflower", ha: 4)]),
        ])
        XCTAssertEqual(crops.count, 2, "a blank or missing crop was offered, or Wheat split by case")
        let wheatLabel = try XCTUnwrap(CommodityName.freeText("Wheat"))
        let wheat = try XCTUnwrap(crops.first { $0.label == wheatLabel })
        XCTAssertEqual(wheat.fields.map(\.id), ["n1", "s2", "s10"], "by block, then numerically by name")
        XCTAssertEqual(wheat.fields.map(\.blockName), ["Блок Север", "Блок Юг", "Блок Юг"])
    }

    /// Two spellings of one crop — the catalogue's and an import's — are one
    /// crop, not two identical menu entries each holding part of it.
    func testSpellingsOfOneCropAreOneCrop() throws {
        let b = try block("b1", "Блок")
        let wheatLabel = try XCTUnwrap(CommodityName.freeText("Wheat"))
        let crops = TreatmentPlace.crops([(b, [parcel("a", "1", crop: "Wheat", ha: 1),
                                               parcel("c", "2", crop: wheatLabel, ha: 1)])])
        XCTAssertEqual(crops.count, 1)
        XCTAssertEqual(crops[0].fields.count, 2)
    }

    /// Bulgarian order, not code-point order: «люцерна» (л) before «Пшеница»
    /// (П) — code points put every capital first and would reverse them.
    func testCropsAreInBulgarianAlphabeticalOrder() throws {
        let b = try block("b1", "Блок")
        let crops = TreatmentPlace.crops([(b, [parcel("a", "1", crop: "Wheat", ha: 1),
                                               parcel("c", "2", crop: "люцерна", ha: 1)])])
        XCTAssertEqual(crops.map(\.label), ["люцерна", try XCTUnwrap(CommodityName.freeText("Wheat"))])
    }

    func testTheTotalIsTheChosenParcelsAndSaysWhatItLeftOut() throws {
        let b = try block("b1", "Блок")
        let fields = TreatmentPlace.crops([(b, [parcel("a", "1", crop: "Wheat", ha: 1.5),
                                                parcel("c", "2", crop: "Wheat", ha: nil),
                                                parcel("d", "3", crop: "Wheat", ha: 2.25)])])[0].fields
        let total = TreatmentPlace.total(fields)
        XCTAssertEqual(total.area, Area(hectares: 3.75))
        XCTAssertEqual(total.parcels, 3)
        XCTAssertEqual(total.withoutArea, 1)
        XCTAssertEqual(TreatmentPlace.total([]).parcels, 0)
    }

    /// A tap inside a field finds it; outside, nothing; where two overlap,
    /// the smaller first.
    func testATapOnTheMapFindsTheFieldUnderIt() throws {
        let b = try block("b1", "Блок")
        let fields = TreatmentPlace.crops([(b, [
            parcel("big", "1", crop: "Wheat", ha: 40, geometry: square(lon: 24.0, lat: 42.0, side: 0.02)),
            parcel("small", "2", crop: "Wheat", ha: 2, geometry: square(lon: 24.005, lat: 42.005, side: 0.005)),
            parcel("none", "3", crop: "Wheat", ha: 1),
        ])])[0].fields
        let inSmall = CLLocationCoordinate2D(latitude: 42.007, longitude: 24.007)
        let outlines = TreatmentPlace.outlines([TreatmentPlace.Crop(key: "x", label: "x", fields: fields)])
        XCTAssertEqual(TreatmentPlace.fields(at: inSmall, in: fields, outlines: outlines).map(\.id), ["small", "big"])
        let inBigOnly = CLLocationCoordinate2D(latitude: 42.018, longitude: 24.018)
        XCTAssertEqual(TreatmentPlace.fields(at: inBigOnly, in: fields, outlines: outlines).map(\.id), ["big"])
        let outside = CLLocationCoordinate2D(latitude: 43.0, longitude: 25.0)
        XCTAssertEqual(TreatmentPlace.fields(at: outside, in: fields, outlines: outlines), [])
    }

    /// A hole is outside its field.
    func testAHoleIsNotPartOfTheField() {
        let outer = [[24.0, 42.0], [24.02, 42.0], [24.02, 42.02], [24.0, 42.02], [24.0, 42.0]]
        let hole = [[24.005, 42.005], [24.015, 42.005], [24.015, 42.015], [24.005, 42.015], [24.005, 42.005]]
        guard let polygon = ParcelGeometry(type: "MultiPolygon", coordinates: [[outer, hole]]).mapPolygons.first else {
            return XCTFail("positive control: the fixture draws")
        }
        XCTAssertFalse(TreatmentPlace.contains(polygon, MKMapPoint(CLLocationCoordinate2D(latitude: 42.01, longitude: 24.01))),
                       "a tap in the hole chose the field")
        XCTAssertTrue(TreatmentPlace.contains(polygon, MKMapPoint(CLLocationCoordinate2D(latitude: 42.002, longitude: 24.002))),
                      "positive control: the ring itself")
    }

    // MARK: - The record

    func testTheRecordNeedsAParcelAndCarriesTheStoredName() throws {
        let b = try block("b1", "Блок")
        let fields = TreatmentPlace.crops([(b, [parcel("p1", "1", crop: "Wheat", ha: 1)])])[0].fields
        var draft = TreatmentDraft(date: today)
        draft.productText = "  познат препарат "
        draft.pestText = " Листни въшки "
        draft.doseText = "40"
        draft.doseUnit = mlPerDca
        draft.quarantineText = "14"
        draft.technique = .ground
        let catalogue = [item("Познат препарат", quarantine: 14)]

        XCTAssertNil(TreatmentRecord.make(draft, catalogue: catalogue, fields: [], now: today), "no parcel, no record")
        let record = try XCTUnwrap(TreatmentRecord.make(draft, catalogue: catalogue, fields: fields, now: today))
        XCTAssertEqual(record.productName, "Познат препарат", "the stored name, so the server meets that row")
        XCTAssertNil(record.newProduct)
        XCTAssertEqual(record.pest, "Листни въшки")
        XCTAssertEqual(record.quarantineDays, 14)
        XCTAssertEqual(record.technique, .ground)
        XCTAssertEqual(record.doseUnitID, "u-ml")
        XCTAssertEqual(record.parcelIDs, ["p1"])
    }

    func testANewPesticideCarriesItsRegistrationAndFertilisingCarriesNoChemicalColumns() throws {
        let b = try block("b1", "Блок")
        let fields = TreatmentPlace.crops([(b, [parcel("p1", "1", crop: "Wheat", ha: 1)])])[0].fields
        var spray = TreatmentDraft(date: today)
        spray.productText = "Нов препарат"
        spray.registrationText = " 0123 "
        spray.pestText = "Плевели"
        spray.doseText = "1"; spray.doseUnit = mlPerDca; spray.quarantineText = "0"
        let new = try XCTUnwrap(TreatmentRecord.make(spray, catalogue: [], fields: fields, now: today))
        XCTAssertEqual(new.newProduct, .init(pppRegistrationNo: "0123", quarantineDays: 0))

        var fert = spray
        fert.kind = .fertilize
        let fertilising = try XCTUnwrap(TreatmentRecord.make(fert, catalogue: [], fields: fields, now: today))
        XCTAssertNil(fertilising.newProduct)
        XCTAssertNil(fertilising.quarantineDays)
        XCTAssertNil(fertilising.pest)
        XCTAssertNil(fertilising.technique)
    }
}

/// The store reads every block's parcels, and a block it cannot read is
/// counted rather than silently missing.
@MainActor
final class TreatmentPlaceStoreTests: XCTestCase {

    private func block(_ id: String) throws -> Location {
        try JSONDecoder().decode(Location.self, from: Data("""
        {"id":"\(id)","name":"Блок \(id)","description":null,"status":"ACTIVE","capacityTonnes":null}
        """.utf8))
    }

    private func parcels(_ block: String, _ crop: String) -> ParcelsResponse {
        ParcelsResponse(locationId: block, bounds: nil, parcels: [
            Parcel(id: "\(block)-1", name: "1", cropType: crop, areaHa: 1, geometry: nil, soilType: nil,
                   cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil),
        ])
    }

    func testABlockThatCannotBeReadIsCounted() async throws {
        let blocks = [try block("a"), try block("b")]
        let store = TreatmentPlaceStore(
            loadBlocks: { .loaded(blocks, .fresh) },
            loadParcels: { id in id == "a" ? .loaded(self.parcels("a", "Wheat"), .fresh) : .failed("Няма връзка.") }
        )
        await store.load()
        XCTAssertEqual(store.state.value?.map(\.fields.count), [1])
        XCTAssertEqual(store.outlines.count, 1, "the outlines were not built with the list")
        XCTAssertEqual(store.unreadBlocks, 1)
    }

    func testNoBlockReadIsAFailureNotAnEmptyFarm() async throws {
        let blocks = [try block("a")]
        let store = TreatmentPlaceStore(loadBlocks: { .loaded(blocks, .fresh) },
                                        loadParcels: { _ in .failed("Няма връзка.") })
        await store.load()
        XCTAssertEqual(store.state, .failed("Няма връзка."))

        let none = TreatmentPlaceStore(loadBlocks: { .failed("Сървърът не отговори.") },
                                       loadParcels: { _ in .failed("x") })
        await none.load()
        XCTAssertEqual(none.state, .failed("Сървърът не отговори."))
    }
}
