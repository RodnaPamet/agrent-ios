import XCTest
@testable import Agrent

/// «Нов запис» saved with no signal (agrent-ios#324): the row the outbox
/// keeps, its replay under the treatment's handle, a delivery that holds
/// fewer parcels than were sent, and what the journal shows while it waits.
/// Synthetic throughout; nothing here reaches a network.
@MainActor
final class OutboxTreatmentTests: XCTestCase {

    private let owner = "usr-a-0001"
    private var directories: [String] = []

    override func tearDown() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in directories {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        directories = []
    }

    private func makeQueue() -> PendingOperations {
        let name = "OutboxTreatment-\(UUID().uuidString)"
        directories.append(name)
        return PendingOperations(directoryName: name)
    }

    /// What the drain sent, and how each send is answered.
    private final class Wire {
        var sent: [PendingOperation] = []
        var answer: (PendingOperation) async throws -> Void = { _ in }
    }

    private func makeOutbox(_ queue: PendingOperations, _ wire: Wire) -> OutboxStore {
        let owner = owner
        return OutboxStore(queue: queue, currentOwner: { owner }, identify: {}, send: { item in
            wire.sent.append(item)
            try await wire.answer(item)
        })
    }

    private let facts = PendingOperation.QueuedTreatment(
        kind: "SPRAY", productName: "Тестов хербицид", occurredOn: "2026-10-14", parcelCount: 3,
        areaHa: 4.2, blockNames: ["Блок 2", "Блок 5"])

    private func row(handle: String = UUID().uuidString, farm: String? = "test-farm") -> PendingOperation {
        .treatment(handle: handle, facts, ownerUserID: owner, farm: farm,
                   payload: Data(#"{"kind":"SPRAY"}"#.utf8), reason: nil)
    }

    // MARK: - The row

    /// The handle is the row's id, so the key of every replay is the key the
    /// live save went out under — the one a lost answer may already have
    /// recorded the treatment with.
    func testATreatmentReplaysUnderItsHandleToTheFarmItWasMadeOn() {
        let item = row(handle: "6F1C2D3E-0000-4000-8000-000000000001", farm: "farm-b")
        XCTAssertEqual(item.id, "6F1C2D3E-0000-4000-8000-000000000001")
        XCTAssertEqual(item.target, .treatment(facts))
        XCTAssertNil(item.locationID, "a treatment names no location; the server groups its parcels")
        XCTAssertEqual(OutboxStore.replay(for: item),
                       .treatment(path: TreatmentAPI.recordPath(tenant: "farm-b"),
                                  handle: "6F1C2D3E-0000-4000-8000-000000000001", parcels: 3))
        XCTAssertTrue(TreatmentAPI.recordPath(tenant: "farm-b").hasSuffix("/farm-b/journal/treatments"),
                      TreatmentAPI.recordPath(tenant: "farm-b"))
    }

    /// What the banner names under its count: product, kind, parcels.
    func testTheBannerNamesTheTreatment() {
        XCTAssertEqual(row().parcelSummary, "Тестов хербицид · Пръскане · 3 парцела")
    }

    /// Through the disk and back, and a row written before #324 still reads
    /// as the create it was: the new field is Optional, or every queued
    /// spray already on a phone would stop decoding and vanish from the queue.
    func testItRoundTripsAndOlderRowsStillRead() async throws {
        let item = row()
        let back = try JSONDecoder().decode(PendingOperation.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)

        let older = Data(#"""
        {"id":"0A0B0C0D-0000-4000-8000-000000000002","locationID":"loc","parcelSummary":"SYNTH-1 · Пръскане",
         "payload":"e30=","createdAt":800000000,"attempts":0,"isRefused":false}
        """#.utf8)
        let create = try JSONDecoder().decode(PendingOperation.self, from: older)
        XCTAssertNil(create.treatment)
        XCTAssertEqual(create.target, .create(locationID: "loc"))

        let queue = makeQueue()
        await queue.enqueue(item)
        let stored = await queue.all()
        XCTAssertEqual(stored, [item])
    }

    // MARK: - The delivery

    /// A 201 on fewer parcels than were sent is not a delivery; all of them
    /// is, and so is an answer that cannot be read — the treatment is on the
    /// register either way, as `TreatmentAPI.receipt` reads one live.
    func testADeliveryOnFewerParcelsIsNotADelivery() {
        let short = Data(#"{"treatmentGroupId":"H","parcelCount":2}"#.utf8)
        XCTAssertThrowsError(try OutboxStore.delivered(short, handle: "H", parcels: 3)) { error in
            XCTAssertEqual(error as? TreatmentAttempt.Shortfall, .init(recorded: 2, sent: 3))
        }
        XCTAssertNoThrow(try OutboxStore.delivered(Data(#"{"treatmentGroupId":"H","parcelCount":3}"#.utf8),
                                                   handle: "H", parcels: 3))
        XCTAssertNoThrow(try OutboxStore.delivered(Data("not json".utf8), handle: "H", parcels: 3))
        XCTAssertTrue(PendingOperations.isWorthRetrying(TreatmentAttempt.Shortfall(recorded: 2, sent: 3)),
                      "a short delivery would be refused, with part of the treatment off the register")
    }

    /// The pass that met the short answer keeps the row, refuses nothing, and
    /// the next sends the same handle, which writes the rest.
    func testAShortDeliveryIsSentAgainUnderItsHandle() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire)
        var answers: [Error?] = [TreatmentAttempt.Shortfall(recorded: 2, sent: 3), nil]
        wire.answer = { _ in if let error = answers.removeFirst() { throw error } }
        let item = row()
        await outbox.enqueue(item)

        await outbox.flush()
        let kept = await queue.all()
        XCTAssertEqual(kept.map(\.id), [item.id])
        XCTAssertEqual(kept.first?.isRefused, false)
        XCTAssertEqual(kept.first?.attempts, 1)

        await outbox.flush()
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "the finished treatment is still queued")
        XCTAssertEqual(wire.sent.map(\.id), [item.id, item.id], "a second key would be a second treatment")
    }

    /// The route's refusal is kept with its Bulgarian sentence — the only
    /// copy of the entry, and a person needs to read why.
    func testARefusedTreatmentIsKeptWithTheServersSentence() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire)
        let refusal = APIClient.APIError.http(status: 400, code: "TREATMENT_DATE_IN_FUTURE", message: nil)
        wire.answer = { _ in throw refusal }
        await outbox.enqueue(row())
        await outbox.flush()

        let refused = await queue.all().first
        XCTAssertEqual(refused?.isRefused, true)
        XCTAssertNil(refused?.conflict, "a treatment has no line to keep or drop")
        XCTAssertEqual(refused?.lastError, UserMessage.text(for: refusal))
    }

    /// agrent-ios#326. A row that kept coming back short is abandoned by an
    /// administrator. The server no longer resumes the handle, and without
    /// its 410 the next send would write the whole treatment again
    /// (agri-saas #1869). So the 410 refuses the row, says so in Bulgarian,
    /// and no later pass sends that handle again.
    func testAnAbandonedTreatmentIsRefusedAndNeverSentAgain() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire)
        let gone = APIClient.APIError.http(status: 410, code: "TREATMENT_ABANDONED",
                                           message: "This treatment was abandoned by an administrator.")
        var answers: [Error] = [TreatmentAttempt.Shortfall(recorded: 1, sent: 3), gone]
        wire.answer = { _ in throw answers.isEmpty ? gone : answers.removeFirst() }
        let item = row()
        await outbox.enqueue(item)

        await outbox.flush()
        await outbox.flush()
        let refused = await queue.all().first
        XCTAssertEqual(refused?.isRefused, true)
        XCTAssertEqual(refused?.lastError, UserMessage.text(for: gone))
        XCTAssertTrue(UserMessage.isBulgarianSentence(refused?.lastError ?? ""), refused?.lastError ?? "nil")

        await outbox.flush()
        XCTAssertEqual(wire.sent.map(\.id), [item.id, item.id], "an abandoned handle went out again")
    }

    /// #326. Each short answer is noted on the row, and one that holds no
    /// more than the last says resending has stopped getting further.
    func testAShortAnswerIsNotedAndAStallIsSeen() async {
        let queue = makeQueue(), wire = Wire(), outbox = makeOutbox(queue, wire)
        var answers: [Error] = [TreatmentAttempt.Shortfall(recorded: 1, sent: 3),
                                TreatmentAttempt.Shortfall(recorded: 2, sent: 3),
                                TreatmentAttempt.Shortfall(recorded: 2, sent: 3)]
        wire.answer = { _ in if !answers.isEmpty { throw answers.removeFirst() } }
        await outbox.enqueue(row())

        await outbox.flush()
        var kept = await queue.all().first?.treatment
        XCTAssertEqual(kept?.recorded, 1)
        XCTAssertEqual(kept?.stalled, false)
        XCTAssertEqual(kept?.partialText, "Записан 1 от 3 парцела. Останалите се изпращат отново.")

        await outbox.flush()
        kept = await queue.all().first?.treatment
        XCTAssertEqual(kept?.recorded, 2)
        XCTAssertEqual(kept?.stalled, false, "two more parcels is progress")

        await outbox.flush()
        kept = await queue.all().first?.treatment
        XCTAssertEqual(kept?.stalled, true)
        XCTAssertEqual(kept?.partialText, "Записани 2 от 3 парцела. Останалите не могат да бъдат записани.")
        let refused = await queue.all().first?.isRefused
        XCTAssertEqual(refused, false, "still resent: the server may yet finish it")
    }

    /// A row from before #326 has neither note, and says it is waiting.
    func testARowWithoutAShortAnswerSaysNothingOfOne() {
        XCTAssertNil(facts.partialText)
        XCTAssertNil(facts.recorded)
    }

    /// The abandon, apart from its screen: the server's, then the phone's
    /// copy, so nothing sends the handle again.
    private actor Abandoner: TreatmentRecorder {
        private let answer: Error?
        private(set) var abandoned: [String] = []
        init(_ answer: Error? = nil) { self.answer = answer }

        func abandon(_ handle: String) async throws {
            abandoned.append(handle)
            if let answer { throw answer }
        }

        func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt {
            throw URLError(.unsupportedURL)
        }
        func landing(of handle: String) async throws -> TreatmentLanding { throw URLError(.unsupportedURL) }
        func document(forTreatment handle: String) async throws -> URL { throw URLError(.unsupportedURL) }
        func keep(_ entry: TreatmentAttempt.Sent, after error: Error) async -> Bool { false }
        func progress(of handle: String) async throws -> TreatmentProgress? { nil }
    }

    func testAnAbandonForgetsThePhonesCopy() async {
        let queue = makeQueue(), outbox = makeOutbox(queue, Wire())
        let item = row()
        await outbox.enqueue(item)
        let server = Abandoner()

        let outcome = await TreatmentAbandon.run(item.id, with: server, outbox: outbox)
        XCTAssertEqual(outcome, .abandoned)
        let asked = await server.abandoned
        XCTAssertEqual(asked, [item.id])
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "the phone would send an abandoned handle again")
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    /// Abandoned already, from the web or another phone: the server holds
    /// nothing under the handle, which is the end this was for.
    func testAnAbandonAlreadyDoneElsewhereCountsAsDone() async {
        let queue = makeQueue(), outbox = makeOutbox(queue, Wire())
        let item = row()
        await outbox.enqueue(item)
        let gone = APIClient.APIError.http(status: 404, code: "TREATMENT_NOT_FOUND", message: nil)

        let outcome = await TreatmentAbandon.run(item.id, with: Abandoner(gone), outbox: outbox)
        XCTAssertEqual(outcome, .abandoned)
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty)
    }

    /// Finished meanwhile, or refused: said in Bulgarian, and the phone's
    /// copy stays, since the treatment does.
    func testATreatmentThatWasNotAbandonedKeepsItsRow() async {
        let queue = makeQueue(), outbox = makeOutbox(queue, Wire())
        let item = row()
        await outbox.enqueue(item)
        for refusal in [APIClient.APIError.http(status: 409, code: "TREATMENT_COMPLETE", message: "This treatment is fully recorded."),
                        APIClient.APIError.http(status: 403, code: "FORBIDDEN", message: "You do not have permission.")] {
            let outcome = await TreatmentAbandon.run(item.id, with: Abandoner(refusal), outbox: outbox)
            guard case .failed(let text) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(UserMessage.isBulgarianSentence(text), text)
            XCTAssertNotEqual(text, UserMessage.statusText(409))
        }
        let left = await queue.all()
        XCTAssertEqual(left.map(\.id), [item.id])
    }

    /// What the confirmation says goes: the whole treatment, and the
    /// entries already on the register by count.
    func testTheConfirmationNamesWhatGoes() {
        let some = TreatmentAbandon.confirmationText(completed: 2)
        XCTAssertTrue(some.contains("2 парцела"), some)
        XCTAssertTrue(UserMessage.isBulgarianSentence(some), some)
        let one = TreatmentAbandon.confirmationText(completed: 1)
        XCTAssertTrue(one.contains("1 парцел,"), one)
        let none = TreatmentAbandon.confirmationText(completed: 0)
        XCTAssertFalse(none.contains("0"), none)
        XCTAssertTrue(UserMessage.isBulgarianSentence(none), none)
        XCTAssertTrue(UserMessage.isBulgarianSentence(TreatmentAbandon.askAnAdministrator))
    }

    /// The server's counts, read strictly: they decide whether the abandon,
    /// which removes ДНЕВНИК entries, is offered at all.
    func testProgressIsReadStrictly() throws {
        let body = #"{"treatmentGroupId":"h-1","parcelCount":3,"completedCount":2,"taskIds":["t1"],"occurredOn":null,"complete":false}"#
        XCTAssertEqual(try TreatmentAPI.progress(from: Data(body.utf8)),
                       TreatmentProgress(parcelCount: 3, completedCount: 2, complete: false))
        XCTAssertThrowsError(try TreatmentAPI.progress(from: Data(#"{"parcelCount":3,"complete":false}"#.utf8)))
    }

    // MARK: - The journal

    private func entry(handle: String?) -> LogEntry {
        LogEntry(id: "log_\(UUID().uuidString)", type: .inputApplication, status: .done, title: nil,
                 notes: nil, occurredAt: nil, version: 1,
                 treatment: JournalTreatment(treatmentGroupId: handle, productName: "Тестов хербицид",
                                             parcelCount: 3))
    }

    /// This farm's kept treatments, and only those the list does not
    /// already hold: a lost answer that landed comes back in the reload
    /// under the same handle, and one treatment shown twice reads as two.
    func testTheJournalShowsThisFarmsWaitingTreatmentsOnce() {
        let here = row(farm: "test-farm"), landed = row(farm: "test-farm"), elsewhere = row(farm: "farm-b")
        let spray = PendingOperation(
            id: UUID().uuidString, locationID: "loc", ownerUserID: owner, tenantSlug: "test-farm",
            parcelSummary: "SYNTH-1 · Пръскане", payload: Data(), createdAt: Date(),
            attempts: 0, lastAttemptAt: nil, lastError: nil)
        let waiting = JournalStore.waiting(in: [here, landed, elsewhere, spray], farm: "test-farm",
                                           listed: [entry(handle: landed.id), entry(handle: nil)])
        XCTAssertEqual(waiting.map(\.id), [here.id])
        XCTAssertTrue(JournalStore.waiting(in: [here], farm: nil, listed: []).isEmpty,
                      "with no farm open, no farm's treatments are this one's")
    }

    /// The server's row stands in for a treatment that came back short, so
    /// that row is where the rest is said to be missing: this farm's, and
    /// only those with a short answer noted.
    func testTheJournalFindsThisFarmsShortTreatments() {
        var short = row(handle: "h-short")
        short.treatment?.cameBackShort(recorded: 2)
        var elsewhere = row(handle: "h-elsewhere", farm: "other-farm")
        elsewhere.treatment?.cameBackShort(recorded: 1)
        let waiting = row(handle: "h-waiting")

        let found = JournalStore.partial(in: [short, elsewhere, waiting], farm: "test-farm")
        XCTAssertEqual(Set(found.keys), ["h-short"])
        XCTAssertEqual(found["h-short"]?.recorded, 2)
        XCTAssertTrue(JournalStore.partial(in: [short], farm: nil).isEmpty)
    }
}
