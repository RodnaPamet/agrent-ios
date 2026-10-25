import XCTest
@testable import Agrent

/// Other work from «Нов запис»: pruning, cultivation, harvest (#439;
/// agri-saas `/journal/activities`, owner 2026-10-25). Pure: nothing here
/// reaches the server.
final class ActivityEntryTests: XCTestCase {

    private let today = BgDate.parseISODay("2026-10-25")!

    private func field(_ id: String, ha: Double?) throws -> TreatmentPlace.Field {
        let json = #"{"id":"\#(id)","name":"Парцел \#(id)","areaHa":\#(ha.map { "\($0)" } ?? "null")}"#
        let parcel = try JSONDecoder().decode(Parcel.self, from: Data(json.utf8))
        return TreatmentPlace.Field(parcel: parcel, blockID: "b1", blockName: "Блок 1")
    }

    private func draft(_ work: ActivityKind, harvest: String = "") -> TreatmentDraft {
        var draft = TreatmentDraft(date: today)
        draft.entryKind = .activity(work)
        draft.harvestText = harvest
        return draft
    }

    private func json(_ body: ActivityAPI.Body) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    /// The server's words, so the phone and the diary name the work alike;
    /// «Обработка на почвата» in full.
    func testTheLabelsAreTheServers() {
        XCTAssertEqual(ActivityKind.allCases.map(\.label), ["Резитба", "Обработка на почвата", "Прибиране на реколтата"])
        XCTAssertEqual(EntryKind.all.map(\.label),
                       ["Пръскане", "Торене", "Резитба", "Обработка на почвата", "Прибиране на реколтата"])
    }

    /// Other work asks only for its day; a harvest for its quantity too.
    func testOtherWorkAsksForNoProductOrDose() {
        XCTAssertEqual(draft(.prune).problems(catalogue: [], now: today), [])
        XCTAssertEqual(draft(.harvest).problems(catalogue: [], now: today), [.harvestMissing])
        XCTAssertEqual(draft(.harvest, harvest: "0").problems(catalogue: [], now: today), [.harvestMissing])
        XCTAssertEqual(draft(.harvest, harvest: "1250,5").problems(catalogue: [], now: today), [])
        var future = draft(.cultivate)
        future.date = BgDate.parseISODay("2026-10-26")!
        XCTAssertEqual(future.problems(catalogue: [], now: today), [.futureDate])
    }

    /// Choosing a kind back from other work restores the treatment.
    func testTheKindRoundTrips() {
        var form = draft(.prune)
        XCTAssertEqual(form.entryKind, .activity(.prune))
        form.entryKind = .treatment(.fertilize)
        XCTAssertNil(form.activity)
        XCTAssertEqual(form.kind, .fertilize)
    }

    /// The activities route's body: the kind, the day, every parcel with its
    /// area (a whole one as its own), and a harvest's one total.
    func testTheBodyIsTheActivitysOwn() throws {
        let fields = [try field("p1", ha: 2), try field("p2", ha: nil)]
        var harvest = draft(.harvest, harvest: "1250")
        harvest.treatedText = [:]
        let record = try XCTUnwrap(TreatmentRecord.make(harvest, catalogue: [], fields: fields, now: today))
        XCTAssertEqual(record.activity, .harvest)
        let body = try json(try XCTUnwrap(ActivityAPI.Body(record)))
        XCTAssertEqual(Set(body.keys), ["kind", "occurredOn", "parcelIds", "parcels", "harvestKg"])
        XCTAssertEqual(body["kind"] as? String, "HARVEST")
        XCTAssertEqual(body["occurredOn"] as? String, "2026-10-25")
        XCTAssertEqual(body["parcelIds"] as? [String], ["p1", "p2"])
        XCTAssertEqual((body["parcels"] as? [[String: Any]])?.map { $0["parcelId"] as? String }, ["p1"],
                       "a parcel with no area is the whole parcel")
        XCTAssertEqual(body["harvestKg"] as? Double, 1250)

        let pruning = try XCTUnwrap(TreatmentRecord.make(draft(.prune), catalogue: [], fields: fields, now: today))
        XCTAssertNil(try json(try XCTUnwrap(ActivityAPI.Body(pruning)))["harvestKg"], "only a harvest has a quantity")
    }

    /// The server's bound is over zero: a parcel recorded with area 0 goes
    /// out as the whole parcel, left out, never as a 0 it refuses.
    func testAZeroAreaParcelIsTheWholeParcel() throws {
        let fields = [try field("p1", ha: 2), try field("p0", ha: 0)]
        let record = try XCTUnwrap(TreatmentRecord.make(draft(.prune), catalogue: [], fields: fields, now: today))
        let body = try json(try XCTUnwrap(ActivityAPI.Body(record)))
        XCTAssertEqual((body["parcels"] as? [[String: Any]])?.map { $0["parcelId"] as? String }, ["p1"])
    }

    /// The activities route says `lines` where the treatments route says
    /// `parcelCount`: either is the count a short save is caught by.
    func testTheReceiptReadsEitherCount() {
        let activity = TreatmentAPI.receipt(from: Data(#"{"treatmentGroupId":"h1","tasks":1,"lines":3,"occurredOn":"2026-10-25","harvestQuantityId":null}"#.utf8), key: "h1")
        XCTAssertEqual(activity.parcelCount, 3)
        let treatment = TreatmentAPI.receipt(from: Data(#"{"treatmentGroupId":"h1","parcelCount":2}"#.utf8), key: "h1")
        XCTAssertEqual(treatment.parcelCount, 2)
    }

    /// A treatment is no activity: the activities route refuses to build one.
    func testATreatmentHasNoActivityBody() throws {
        var spraying = TreatmentDraft(date: today)
        spraying.productText = "Препарат"
        spraying.registrationText = "0123"
        spraying.pestText = "Плевели"
        spraying.doseText = "1"
        spraying.quarantineText = "14"
        let unit = try JSONDecoder().decode(Agrent.Unit.self, from: Data(#"{"id":"u","key":"l_per_dca","name":null,"symbol":"л/дка","measure":"RATE"}"#.utf8))
        spraying.doseUnit = unit
        let record = try XCTUnwrap(TreatmentRecord.make(spraying, catalogue: [], fields: [try field("p1", ha: 1)], now: today))
        XCTAssertNil(record.activity)
        XCTAssertNil(ActivityAPI.Body(record))
    }

    /// A row kept for later goes to its own route, by the kind it was kept
    /// under; a treatment, and one kept before #439, to the treatments route.
    func testTheOutboxSendsEachToItsRoute() throws {
        func path(_ kind: String) -> String? {
            let row = PendingOperation.treatment(
                handle: "h1", .init(kind: kind, productName: "Х", occurredOn: "2026-10-25", parcelCount: 1,
                                    areaHa: nil, blockNames: []),
                ownerUserID: "u", farm: "ferma", payload: Data("{}".utf8), reason: "")
            if case .treatment(let path, _, _) = OutboxStore.replay(for: row) { return path }
            return nil
        }
        XCTAssertEqual(path("PRUNE"), ActivityAPI.recordPath(tenant: "ferma"))
        XCTAssertEqual(path("SPRAY"), TreatmentAPI.recordPath(tenant: "ferma"))
    }

    func testTheReadBackNamesTheWork() throws {
        let record = try XCTUnwrap(TreatmentRecord.make(draft(.prune), catalogue: [],
                                                        fields: [try field("p1", ha: 1)], now: today))
        XCTAssertEqual(TreatmentCheckView.areaWord(record), "Площ")
        XCTAssertEqual(TreatmentMapView.title(for: record), "Парцели")
        XCTAssertTrue(TreatmentCheckView.kgText(Decimal(1250)).hasSuffix(" кг"))
    }
}
