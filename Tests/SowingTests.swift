import XCTest
@testable import Agrent

/// «Сеитба» in «Нов запис»: a seed variety at a rate, through the treatments
/// route (#439; agri-saas #2368, owner 2026-10-25). Pure: nothing here
/// reaches the server.
final class SowingTests: XCTestCase {

    private let today = BgDate.parseISODay("2026-10-25")!

    private func catalogue() throws -> [InputItem] {
        let json = #"[{"id":"s1","name":"Пшеница Аглика","category":"SEED","defaultUnit":null,"createdByUserId":"u"},{"id":"p1","name":"Препарат А","category":"PESTICIDE","defaultUnit":null,"createdByUserId":"u"},{"id":"f1","name":"Тор Б","category":"FERTILIZER","defaultUnit":null,"createdByUserId":"u"}]"#
        return try JSONDecoder().decode([InputItem].self, from: Data(json.utf8))
    }

    private func unit() throws -> Agrent.Unit {
        try JSONDecoder().decode(Agrent.Unit.self, from: Data(#"{"id":"u_kgha","key":"kg-per-ha","name":null,"symbol":"кг/ха","measure":"RATE"}"#.utf8))
    }

    private func field(_ id: String, ha: Double?) throws -> TreatmentPlace.Field {
        let json = #"{"id":"\#(id)","name":"Парцел \#(id)","areaHa":\#(ha.map { "\($0)" } ?? "null")}"#
        return TreatmentPlace.Field(parcel: try JSONDecoder().decode(Parcel.self, from: Data(json.utf8)),
                                    blockID: "b1", blockName: "Блок 1")
    }

    private func sowing(_ name: String) throws -> TreatmentDraft {
        var draft = TreatmentDraft(date: today)
        draft.entryKind = .treatment(.seed)
        draft.productText = name
        draft.doseText = "220"
        draft.doseUnit = try unit()
        return draft
    }

    /// Each kind takes its own products: a sowing a seed, a spraying anything
    /// but a seed (the server refuses one), a fertilising a fertiliser.
    func testEachKindTakesItsOwnProducts() throws {
        let items = try catalogue()
        XCTAssertEqual(TypedProduct.classify("Пшеница Аглика", use: .seed, catalogue: items), .existing(items[0]))
        XCTAssertEqual(TypedProduct.classify("Препарат А", use: .seed, catalogue: items), .wrongKind(items[1]))
        XCTAssertEqual(TypedProduct.classify("Нов сорт", use: .seed, catalogue: items), .new)
        XCTAssertEqual(TypedProduct.classify("Пшеница Аглика", use: .product, catalogue: items), .wrongKind(items[0]))
        XCTAssertEqual(TypedProduct.classify("Тор Б", use: .product, catalogue: items), .existing(items[2]),
                       "the product path still takes a fertiliser")
        XCTAssertEqual(TypedProduct.classify("Пшеница Аглика", use: .fertilizer, catalogue: items), .wrongKind(items[0]))
        XCTAssertEqual(TypedProduct.suggestions(for: "пш", use: .seed, in: items).map(\.id), ["s1"])
        XCTAssertEqual(TypedProduct.suggestions(for: "пш", use: .product, in: items), [], "no seed offered to a spraying")
    }

    /// Where a product of the wrong kind belongs, said in words.
    func testAWrongKindSaysWhereItBelongs() throws {
        let items = try catalogue()
        XCTAssertEqual(TreatmentDraft.Kind.spray.wrongKindText(items[0]), "«Пшеница Аглика» е семе. Запишете го като «Сеитба».")
        XCTAssertEqual(TreatmentDraft.Kind.fertilize.wrongKindText(items[0]), "«Пшеница Аглика» е семе. Запишете го като «Сеитба».")
        XCTAssertTrue(TreatmentDraft.Kind.seed.wrongKindText(items[1]).hasPrefix("«Препарат А» не е семе."))
        XCTAssertEqual(TreatmentDraft.Kind.fertilize.wrongKindText(items[1]), "«Препарат А» не е тор. Запишете го като «Пръскане».")
    }

    /// A sowing asks for its seed and its rate, and nothing a spraying
    /// alone needs: no pest, no period, no registration for a new seed.
    func testASowingAsksForItsSeedAndRate() throws {
        XCTAssertEqual(try sowing("Нов сорт").problems(catalogue: try catalogue(), now: today), [])
        var noRate = try sowing("Пшеница Аглика")
        noRate.doseText = ""
        XCTAssertEqual(noRate.problems(catalogue: try catalogue(), now: today), [.doseMissing])
        XCTAssertEqual(try sowing("").problems(catalogue: try catalogue(), now: today).first, .product("Въведете сорта."))
        XCTAssertEqual(TreatmentDraft.Kind.seed.productField, "Сорт")
        XCTAssertEqual(TreatmentDraft.Kind.seed.doseWord, "Сеитбена норма")
        let wrong = try sowing("Препарат А").problems(catalogue: try catalogue(), now: today)
        XCTAssertEqual(wrong.first, .product("«Препарат А» не е семе. Изберете сорт от каталога или въведете нов."))
    }

    /// The treatments route's body with `kind: SEED`: the seed by
    /// `productName`, the rate as the dose, and none of a spraying's fields.
    func testTheBodyIsASowings() throws {
        let record = try XCTUnwrap(TreatmentRecord.make(try sowing("Нов сорт"), catalogue: try catalogue(),
                                                        fields: [try field("p1", ha: 1)], now: today))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TreatmentAPI.Body(record)))
            as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "SEED")
        XCTAssertEqual(body["productName"] as? String, "Нов сорт")
        XCTAssertNil(body["fertilizerName"])
        XCTAssertNil(body["pppRegistrationNo"], "a seed has no ПРЗ №")
        XCTAssertNil(body["targetNote"])
        XCTAssertNil(body["quarantinePeriodDays"])
        XCTAssertNil(body["applicationTechnique"])
        XCTAssertEqual(body["doseValue"] as? Double, 220)
        XCTAssertEqual(body["doseUnitId"] as? String, "u_kgha")
    }

    /// Finishing a sowing sends its seed by id as a product, not a fertiliser.
    func testFinishingASowingSendsItsSeedAsAProduct() throws {
        let definition = TreatmentDefinition(
            treatmentGroupId: "tg_1", version: 1, kind: "SEED", occurredOn: "2026-10-20",
            applicationTechnique: nil, targetNote: nil, productItemId: "s1", productName: "Пшеница Аглика",
            pppRegistrationNo: nil, doseValue: 220, doseUnitId: "u_kgha", doseUnitSymbol: "кг/ха",
            waterRateValue: nil, waterRateUnitSymbol: nil, quarantinePeriodDays: nil, phenophase: nil,
            lines: [.init(parcelId: "p1", parcelName: "Парцел 1", locationId: "b1", treatedAreaHa: 1)])
        let body = try XCTUnwrap(TreatmentAPI.Body(resuming: definition))
        XCTAssertEqual(body.productItemId, "s1")
        XCTAssertNil(body.fertilizerItemId)

        // A correction opens it as a sowing, with none of a spraying's fields.
        let form = TreatmentCorrection.Draft(definition)
        XCTAssertEqual(form.kind, .seed)
        XCTAssertFalse(form.spraying)
        XCTAssertEqual(TreatmentCorrection.Draft.wrongKindText("Препарат А", kind: .seed),
                       "«Препарат А» не е семе. Изберете сорт от каталога на стопанството.")
    }

    /// The words a sowing is read back in, and that it has no ДНЕВНИК page.
    func testASowingsWords() {
        XCTAssertEqual(TreatmentDraft.Kind.seed.areaWord, "Засята площ")
        XCTAssertEqual(TreatmentDraft.Kind.seed.neededWord, "Нужни семена")
        XCTAssertEqual(TreatmentMapView.title(for: .seed), "Засети парцели")
        XCTAssertFalse(TreatmentDraft.Kind.seed.isInBabhRegister)
        XCTAssertTrue(TreatmentDraft.Kind.spray.isInBabhRegister)
        XCTAssertTrue(UserMessage.text(for: APIClient.APIError.http(status: 404, code: "NOT_IN_BABH_REGISTER", message: nil))
            .hasPrefix("Сеитбата не е част от дневника на БАБХ"))
    }
}
