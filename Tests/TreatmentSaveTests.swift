import XCTest
@testable import Agrent

/// «Ново мероприятие»'s save (agrent-ios#293) against agri-saas #1740's
/// contract: the body, the two answers read off the wire, and what one press
/// of «Запази» does when an earlier save was never answered. Synthetic
/// fixtures throughout; nothing here reaches a network.
final class TreatmentSaveTests: XCTestCase {

    private let day = BgDate.parseInstant("2026-10-13T09:00:00.000Z")!
    private let mlPerDca = Agrent.Unit(id: "u-ml", key: "ml_dca", name: "милилитър на декар",
                                       symbol: "мл/дка", measure: "RATE")

    private func field(_ id: String, block: String = "Блок") -> TreatmentPlace.Field {
        let parcel = Parcel(id: id, name: id, cropType: "Wheat", areaHa: 1, geometry: nil, soilType: nil,
                            cadastralId: nil, ekatte: nil, hasActiveLease: nil, absentFromImportAt: nil)
        return TreatmentPlace.Field(parcel: parcel, blockID: "b-\(block)", blockName: block)
    }

    private var fields: [TreatmentPlace.Field] { [field("p1"), field("p2", block: "Втори")] }

    /// A complete spray of a product the farm does not have yet.
    private func spray(_ product: String = "Нов препарат") -> TreatmentDraft {
        var draft = TreatmentDraft(date: day)
        draft.productText = product
        draft.registrationText = "0123"
        draft.pestText = "Листни въшки"
        draft.doseText = "40"
        draft.doseUnit = mlPerDca
        draft.quarantineText = "14"
        draft.technique = .ground
        return draft
    }

    private func record(_ draft: TreatmentDraft, catalogue: [InputItem] = []) throws -> TreatmentRecord {
        try XCTUnwrap(TreatmentRecord.make(draft, catalogue: catalogue, fields: fields, now: day))
    }

    private func json(_ body: TreatmentAPI.Body) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - The body

    /// `RecordDiaryTreatment`'s properties and the five it requires, as
    /// agri-saas #1758's spec lists them.
    private let specKeys: Set<String> = [
        "kind", "occurredOn", "parcelIds", "productItemId", "productName", "fertilizerItemId",
        "fertilizerName", "pppRegistrationNo", "quarantinePeriodDays", "newProductCategory",
        "targetNote", "doseValue", "doseUnitId", "applicationTechnique", "title",
    ]
    private let specRequired: Set<String> = ["kind", "occurredOn", "parcelIds", "doseValue", "doseUnitId"]

    func testASprayOfANewProductCarriesEveryChemicalColumn() throws {
        let body = try json(TreatmentAPI.Body(record(spray())))
        XCTAssertEqual(body["kind"] as? String, "SPRAY")
        XCTAssertEqual(body["occurredOn"] as? String, BgDate.isoDay(day), "a calendar day, not an instant")
        XCTAssertEqual(body["parcelIds"] as? [String], ["p1", "p2"], "one flat list across blocks")
        XCTAssertEqual(body["productName"] as? String, "Нов препарат")
        XCTAssertEqual(body["pppRegistrationNo"] as? String, "0123")
        XCTAssertEqual(body["quarantinePeriodDays"] as? Int, 14)
        XCTAssertEqual(body["targetNote"] as? String, "Листни въшки")
        XCTAssertEqual(body["doseValue"] as? Double, 40)
        XCTAssertEqual(body["doseUnitId"] as? String, "u-ml")
        XCTAssertEqual(body["applicationTechnique"] as? String, "ground", "the slug, never the label")
        XCTAssertNil(body["fertilizerName"])
        XCTAssertTrue(Set(body.keys).isSubset(of: specKeys), "a key the spec does not have: \(body.keys.sorted())")
        XCTAssertTrue(specRequired.isSubset(of: Set(body.keys)))
    }

    /// A product the farm has is sent by its STORED name and without a
    /// registration: the server ignores one on a match, and sending the
    /// field empty would read as a declared registration.
    func testAKnownProductGoesByItsStoredNameAndCarriesNoRegistration() throws {
        var known = InputItem(id: "i1", name: "Познат препарат", category: "PESTICIDE", defaultUnit: nil,
                              createdByUserId: "u1")
        known.quarantinePeriodDays = 21
        var draft = spray("  познат препарат ")
        draft.registrationText = ""
        let body = try json(TreatmentAPI.Body(record(draft, catalogue: [known])))
        XCTAssertEqual(body["productName"] as? String, "Познат препарат")
        XCTAssertNil(body["pppRegistrationNo"])
        XCTAssertEqual(body["quarantinePeriodDays"] as? Int, 14, "the period typed for THIS entry")
    }

    /// The earliest-harvest date the form shows is the one the ДНЕВНИК will
    /// print (#310): the server keeps the period sent with the entry and
    /// prints the treatment's day plus it, so the body must carry exactly the
    /// period the form computed from — for a product the farm already has,
    /// whose own period differs.
    func testTheFormsHarvestDateIsTheOneThePageWillPrint() throws {
        var known = InputItem(id: "i1", name: "Познат препарат", category: "PESTICIDE", defaultUnit: nil,
                              createdByUserId: "u1")
        known.quarantinePeriodDays = 21
        var draft = spray("Познат препарат")
        draft.registrationText = ""
        draft.quarantineText = "7"
        let body = try json(TreatmentAPI.Body(record(draft, catalogue: [known])))
        let days = try XCTUnwrap(body["quarantinePeriodDays"] as? Int)
        XCTAssertEqual(days, 7, "the period typed for this entry, not the product's 21")
        let printed = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: draft.date)
        XCTAssertEqual(draft.earliestHarvest, printed)
    }

    func testFertilisingGoesByTheFertiliserNameAndCarriesNoChemicalColumn() throws {
        var draft = spray("Амониева селитра")
        draft.kind = .fertilize
        let body = try json(TreatmentAPI.Body(record(draft)))
        XCTAssertEqual(body["kind"] as? String, "FERTILIZE")
        XCTAssertEqual(body["fertilizerName"] as? String, "Амониева селитра")
        for absent in ["productName", "pppRegistrationNo", "quarantinePeriodDays", "targetNote",
                       "applicationTechnique"] {
            XCTAssertNil(body[absent], "\(absent) is a chemical column")
        }
        XCTAssertEqual(body["doseValue"] as? Double, 40, "one dose for either kind")
        XCTAssertTrue(specRequired.isSubset(of: Set(body.keys)))
    }

    /// The ДНЕВНИК for one treatment hangs off its handle, in the PATH —
    /// never a query, which iOS writes to the device log.
    func testTheTreatmentsPDFIsUnderItsHandle() {
        XCTAssertTrue(TreatmentAPI.documentPath("h 1").hasSuffix("/journal/treatments/h%201/farm-record"),
                      TreatmentAPI.documentPath("h 1"))
        XCTAssertFalse(TreatmentAPI.documentPath("h1").contains("?"))
    }

    // MARK: - The answers

    func testTheReceiptIsTheHandleAndTheCount() {
        let answer = Data(#"{"treatmentGroupId":"h-1","parcelCount":2,"taskIds":["t1","t2"],"replayed":false}"#.utf8)
        XCTAssertEqual(TreatmentAPI.receipt(from: answer, key: "k"), TreatmentReceipt(handle: "h-1", parcelCount: 2))
    }

    /// A 201 is a treatment on the register whatever its body says: an
    /// unreadable one is not a failure, and its handle is the key it went
    /// out under.
    func testAnUnreadableReceiptIsStillASaveUnderItsKey() {
        XCTAssertEqual(TreatmentAPI.receipt(from: Data("<html>".utf8), key: "k"),
                       TreatmentReceipt(handle: "k", parcelCount: nil))
        XCTAssertEqual(TreatmentAPI.receipt(from: Data("{}".utf8), key: "k"),
                       TreatmentReceipt(handle: "k", parcelCount: nil))
    }

    func testTheSummaryIsLandedOrHalf() throws {
        let landed = #"{"treatmentGroupId":"h","parcelCount":3,"completedCount":3,"taskIds":["t"],"#
            + #""occurredOn":"2026-10-13","complete":true}"#
        // Three lines written, one marked done: on the register in part.
        let half = #"{"treatmentGroupId":"h","parcelCount":3,"completedCount":1,"taskIds":["t"],"#
            + #""occurredOn":"2026-10-13","complete":false}"#
        XCTAssertEqual(try TreatmentAPI.landing(from: Data(landed.utf8)), .landed(parcelCount: 3))
        XCTAssertEqual(try TreatmentAPI.landing(from: Data(half.utf8)), .half)
    }

    /// `complete` is never guessed: without it the answer is a failure, not
    /// "landed" and not "half".
    func testASummaryWithoutCompleteIsNotRead() {
        let body = Data(#"{"treatmentGroupId":"h","parcelCount":3,"completedCount":3,"taskIds":[]}"#.utf8)
        XCTAssertThrowsError(try TreatmentAPI.landing(from: body)) { XCTAssertTrue($0 is DecodingError) }
    }

    /// Only the route's own 404 means nothing landed. A bare one is a server
    /// without the route, and reading it as "nothing" would let a second
    /// treatment be written.
    func testOnlyTheRoutesOwn404MeansNothingLanded() {
        typealias E = APIClient.APIError
        XCTAssertTrue(TreatmentAPI.isNothingRecorded(E.http(status: 404, code: "TREATMENT_NOT_FOUND", message: nil)))
        XCTAssertFalse(TreatmentAPI.isNothingRecorded(E.http(status: 404, code: nil, message: nil)))
        XCTAssertFalse(TreatmentAPI.isNothingRecorded(E.http(status: 404, code: "NOT_FOUND", message: nil)))
        XCTAssertFalse(TreatmentAPI.isNothingRecorded(E.http(status: 500, code: "TREATMENT_NOT_FOUND", message: nil)))
        XCTAssertFalse(TreatmentAPI.isNothingRecorded(URLError(.timedOut)))
    }

    // MARK: - One press of «Запази»

    /// The server, scripted: answers in order, and every call written down.
    private actor Server: TreatmentRecorder {
        enum Call: Equatable {
            case record(key: String, product: String)
            case landing(String)
        }

        private(set) var calls: [Call] = []
        private var records: [Result<Int?, Error>]
        private var landings: [Result<TreatmentLanding, Error>]

        init(records: [Result<Int?, Error>] = [], landings: [Result<TreatmentLanding, Error>] = []) {
            self.records = records
            self.landings = landings
        }

        func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt {
            calls.append(.record(key: idempotencyKey, product: record.productName))
            guard !records.isEmpty else { throw URLError(.badServerResponse) }
            return TreatmentReceipt(handle: idempotencyKey, parcelCount: try records.removeFirst().get())
        }

        func landing(of handle: String) async throws -> TreatmentLanding {
            calls.append(.landing(handle))
            guard !landings.isEmpty else { throw URLError(.badServerResponse) }
            return try landings.removeFirst().get()
        }

        func document(forTreatment handle: String) async throws -> URL { throw URLError(.unsupportedURL) }
    }

    private func press(_ attempt: inout TreatmentAttempt, _ draft: TreatmentDraft,
                       on server: Server) async throws -> TreatmentAttempt.Outcome {
        let made = try record(draft)
        return await attempt.save(made, fields: fields, cropLabel: "Пшеница", entered: draft, with: server)
    }

    func testASaveGoesOutOnceUnderItsKey() async throws {
        let server = Server(records: [.success(2)])
        var attempt = TreatmentAttempt()
        let key = attempt.key
        let outcome = try await press(&attempt, spray(), on: server)

        guard case .saved(let kept, changeLost: false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(kept.key, key)
        XCTAssertEqual(kept.cropLabel, "Пшеница")
        let calls = await server.calls
        XCTAssertEqual(calls, [.record(key: key, product: "Нов препарат")])
        XCTAssertNil(attempt.unsettled)
    }

    /// The same entry pressed again after a lost answer: the same key, and
    /// nothing asked — the server answers a reused key with what it has.
    func testTheSameEntryIsRetriedUnderTheSameKey() async throws {
        let server = Server(records: [.failure(URLError(.timedOut)), .success(2)])
        var attempt = TreatmentAttempt()
        let key = attempt.key

        let first = try await press(&attempt, spray(), on: server)
        XCTAssertEqual(first, .failed(UserMessage.text(for: URLError(.timedOut))))
        XCTAssertEqual(attempt.unsettled?.key, key, "an unanswered save is remembered")

        let second = try await press(&attempt, spray(), on: server)
        guard case .saved(let kept, changeLost: false) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(kept.key, key)
        let calls = await server.calls
        XCTAssertEqual(calls, [.record(key: key, product: "Нов препарат"), .record(key: key, product: "Нов препарат")])
        XCTAssertNil(attempt.unsettled)
    }

    /// A changed entry has a new key, so the earlier one is asked about
    /// first; with nothing under it the changed entry is sent.
    func testAChangedEntryIsSentOnceTheEarlierOneIsKnownNotToHaveLanded() async throws {
        let server = Server(records: [.failure(URLError(.timedOut)), .success(2)], landings: [.success(.nothing)])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        _ = try await press(&attempt, spray("Първи"), on: server)

        let outcome = try await press(&attempt, spray("Втори"), on: server)
        guard case .saved(let kept, changeLost: false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotEqual(kept.key, earlier)
        XCTAssertEqual(kept.record.productName, "Втори")
        let calls = await server.calls
        XCTAssertEqual(calls, [.record(key: earlier, product: "Първи"), .landing(earlier),
                               .record(key: kept.key, product: "Втори")])
    }

    /// THE DUPLICATE THIS EXISTS FOR. The earlier save landed and only its
    /// answer was lost: the changed entry is NOT sent, and what is shown as
    /// saved is the earlier one, said to be without the change.
    func testAChangedEntryIsNotSentWhenTheEarlierOneLanded() async throws {
        let server = Server(records: [.failure(URLError(.timedOut))], landings: [.success(.landed(parcelCount: 2))])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        _ = try await press(&attempt, spray("Първи"), on: server)

        let outcome = try await press(&attempt, spray("Втори"), on: server)
        guard case .saved(let kept, changeLost: true) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(kept.key, earlier, "the handle is the one that landed")
        XCTAssertEqual(kept.record.productName, "Първи", "the screen shows what was recorded")
        let calls = await server.calls
        XCTAssertEqual(calls, [.record(key: earlier, product: "Първи"), .landing(earlier)],
                       "a second treatment was written")
        XCTAssertNil(attempt.unsettled)
    }

    /// Begun and not finished: the EARLIER entry goes out again under its own
    /// key, as it was — the changed one under that key would be answered
    /// with a record made of both.
    func testAHalfLandedSaveIsFinishedAsItWas() async throws {
        let server = Server(records: [.failure(URLError(.networkConnectionLost)), .success(2)],
                            landings: [.success(.half)])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        _ = try await press(&attempt, spray("Първи"), on: server)

        let outcome = try await press(&attempt, spray("Втори"), on: server)
        guard case .saved(let kept, changeLost: true) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(kept.record.productName, "Първи")
        let calls = await server.calls
        XCTAssertEqual(calls, [.record(key: earlier, product: "Първи"), .landing(earlier),
                               .record(key: earlier, product: "Първи")])
    }

    /// "Landed" on fewer parcels than were sent is not landed: it is finished
    /// like a half one, and until the server holds them all nothing is said
    /// to be saved.
    func testFewerParcelsThanSentIsNotSaved() async throws {
        let server = Server(records: [.failure(URLError(.timedOut)), .success(1), .success(2)],
                            landings: [.success(.landed(parcelCount: 1)), .success(.landed(parcelCount: 1))])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        _ = try await press(&attempt, spray("Първи"), on: server)

        let short = try await press(&attempt, spray("Втори"), on: server)
        XCTAssertEqual(short, .failed(TreatmentAttempt.Shortfall(recorded: 1, sent: 2).text))
        XCTAssertEqual(attempt.unsettled?.key, earlier)

        let finished = try await press(&attempt, spray("Втори"), on: server)
        guard case .saved(let kept, changeLost: true) = finished else { return XCTFail("\(finished)") }
        XCTAssertEqual(kept.key, earlier)
        let calls = await server.calls
        XCTAssertEqual(calls.filter { $0 == .record(key: earlier, product: "Първи") }.count, 3)
        XCTAssertFalse(calls.contains { if case .record(_, "Втори") = $0 { true } else { false } },
                       "the changed entry went out beside an unfinished one")
    }

    /// A first save answered short is not a save either, and pressing again
    /// sends the same key, which is what finishes it.
    func testAShortAnswerToAPlainSaveIsAFailure() async throws {
        let server = Server(records: [.success(1), .success(2)])
        var attempt = TreatmentAttempt()
        let key = attempt.key

        let short = try await press(&attempt, spray(), on: server)
        XCTAssertEqual(short, .failed("Сървърът е записал 1 от 2 парцела. Натиснете «Запази» отново."))
        XCTAssertEqual(attempt.unsettled?.key, key)

        let again = try await press(&attempt, spray(), on: server)
        guard case .saved(_, changeLost: false) = again else { return XCTFail("\(again)") }
        let calls = await server.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0 == .record(key: key, product: "Нов препарат") })
    }

    /// The question itself can fail. Then nothing is sent, and the next
    /// press asks again.
    func testNothingIsSentWhileTheEarlierSaveCannotBeAskedAbout() async throws {
        let server = Server(records: [.failure(URLError(.timedOut)), .success(2)],
                            landings: [.failure(URLError(.notConnectedToInternet)), .success(.nothing)])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        _ = try await press(&attempt, spray("Първи"), on: server)

        let blocked = try await press(&attempt, spray("Втори"), on: server)
        XCTAssertEqual(blocked, .failed(UserMessage.text(for: URLError(.notConnectedToInternet))))
        XCTAssertEqual(attempt.unsettled?.key, earlier)
        var calls = await server.calls
        XCTAssertEqual(calls.count, 2, "something was sent without knowing")

        let outcome = try await press(&attempt, spray("Втори"), on: server)
        guard case .saved(_, changeLost: false) = outcome else { return XCTFail("\(outcome)") }
        calls = await server.calls
        XCTAssertEqual(calls.suffix(2).first, .landing(earlier))
    }

    /// A refusal is asked about too — the write is many transactions, and an
    /// error part-way leaves what was committed. What never reached the
    /// server is not.
    func testARefusalIsAskedAboutAndAPhoneSideFailureIsNot() async throws {
        let refused = APIClient.APIError.http(status: 400, code: "TREATMENT_DATE_IN_FUTURE", message: nil)
        let server = Server(records: [.failure(refused), .success(2)], landings: [.success(.nothing)])
        var attempt = TreatmentAttempt()
        let earlier = attempt.key
        let first = try await press(&attempt, spray("Първи"), on: server)
        XCTAssertEqual(first, .failed(TreatmentDraft.Problem.futureDate.text))
        _ = try await press(&attempt, spray("Втори"), on: server)
        var calls = await server.calls
        XCTAssertTrue(calls.contains(.landing(earlier)))

        let local = Server(records: [.failure(APIClient.APIError.notSignedIn), .success(2)])
        var fresh = TreatmentAttempt()
        _ = try await press(&fresh, spray("Първи"), on: local)
        XCTAssertNil(fresh.unsettled)
        _ = try await press(&fresh, spray("Втори"), on: local)
        calls = await local.calls
        XCTAssertFalse(calls.contains { if case .landing = $0 { true } else { false } })
    }

    func testOnlyWhatNeverReachedTheServerLeavesNothing() {
        typealias E = APIClient.APIError
        for error in [E.notSignedIn, E.noFarmOpen, E.clientTooOld] as [Error] {
            XCTAssertFalse(TreatmentAttempt.mayHaveLeftSomething(error), "\(error)")
        }
        for error in [URLError(.timedOut), URLError(.networkConnectionLost),
                      E.http(status: 500, code: nil, message: nil),
                      E.http(status: 400, code: "PRODUCT_IS_SAMPLE_ARCHETYPE", message: nil),
                      E.conflict(currentVersion: nil, expectedVersion: nil),
                      TreatmentAttempt.Shortfall(recorded: 1, sent: 2)] as [Error] {
            XCTAssertTrue(TreatmentAttempt.mayHaveLeftSomething(error), "\(error)")
        }
    }

    /// A change that resolves to the same record — a stray space — lost
    /// nothing, so the saved screen does not say it did.
    func testAChangeThatChangesNothingIsNotSaidToBeLost() async throws {
        let server = Server(records: [.failure(URLError(.timedOut))], landings: [.success(.landed(parcelCount: 2))])
        var attempt = TreatmentAttempt()
        _ = try await press(&attempt, spray("Първи"), on: server)
        let outcome = try await press(&attempt, spray("Първи "), on: server)
        guard case .saved(_, changeLost: false) = outcome else { return XCTFail("\(outcome)") }
    }

    // MARK: - The route's refusals, in Bulgarian

    func testTheRoutesRefusalsAreSaidInBulgarian() {
        let english = "A treatment cannot be recorded for a future date."
        for code in ["TREATMENT_DATE_INVALID", "TREATMENT_DATE_IN_FUTURE", "TREATMENT_NO_PARCELS",
                     "REFERENCE_NOT_IN_TENANT", "PRODUCT_DOSE_REQUIRED", "FERTILIZER_DOSE_REQUIRED",
                     "PRODUCT_NOT_FOUND", "FERTILIZER_NOT_FOUND"] {
            let text = UserMessage.httpText(status: 400, code: code, message: english)
            XCTAssertNotEqual(text, UserMessage.statusText(400), "\(code) has no sentence here")
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), "\(code): \(text)")
        }
        XCTAssertEqual(UserMessage.httpText(status: 400, code: "TREATMENT_DATE_IN_FUTURE", message: english),
                       TreatmentDraft.Problem.futureDate.text, "the form's own sentence")
    }

    /// «Изтегли PDF» after a save: the server holds nothing under the handle.
    /// The read by handle swallows this code; the PDF route says it.
    func testATreatmentWithNothingToPrintIsSaidInBulgarian() {
        let text = UserMessage.httpText(status: 404, code: "TREATMENT_NOT_FOUND",
                                        message: "No treatment was recorded under that handle.")
        XCTAssertNotEqual(text, UserMessage.statusText(404))
        XCTAssertTrue(UserMessage.isBulgarianSentence(text), text)
    }

    /// `params.reference` says which list held the stranger. Parcels are
    /// named; any other list gets the sentence that names none.
    func testAStrangerAmongTheParcelsIsNamedAsAParcel() {
        let parcels = UserMessage.httpText(status: 400, code: "REFERENCE_NOT_IN_TENANT", message: nil,
                                           params: ["reference": "parcels"])
        XCTAssertTrue(parcels.contains("парцели"), parcels)
        let other = UserMessage.httpText(status: 400, code: "REFERENCE_NOT_IN_TENANT", message: nil,
                                         params: ["reference": "locations"])
        XCTAssertFalse(other.contains("парцели"), other)
        XCTAssertEqual(other, UserMessage.httpText(status: 400, code: "REFERENCE_NOT_IN_TENANT", message: nil))
    }
}
