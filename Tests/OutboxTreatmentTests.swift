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
}
