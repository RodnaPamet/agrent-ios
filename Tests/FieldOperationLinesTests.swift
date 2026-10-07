import XCTest
@testable import Agrent

/// A field operation's parcel lines on the task screen — agrent-ios#138.
///
/// NOTHING HERE SENDS A MARK. A real one deducts stock and files a ДНЕВНИК
/// row; the first is the owner's. The store's read, write and encoder are
/// injected closures and its outbox is a private directory, so every outcome
/// of a tap is driven with nothing leaving the process. Where no runtime hook
/// exists — the header `APIClient` puts on the wire — the check reads the
/// source, with a positive control.

// MARK: - Fixtures

/// A line as the route sends it: the raw Prisma row, Decimal columns as
/// strings, the includes, and `version` — which the spec's schema does not
/// list and the route sends anyway.
private func lineJSON(
    id: String = "opl_1", status: String = "PENDING", version: String? = "\"version\":3,",
    areaHa: String = "\"32.478\""
) -> String {
    """
    {"id":"\(id)","tenantId":"ten_x","taskId":"tsk_1","parcelId":"par_1",
     "productItemId":"itm_1","doseValue":"0.25","doseUnitId":"unt_1",
     "waterRateValue":null,"waterRateUnitId":null,"targetNote":null,
     "status":"\(status)","completedAt":null,"completedByUserId":null,
     \(version ?? "")
     "createdAt":"2026-10-03T06:30:00.001Z","updatedAt":"2026-10-03T06:30:00.001Z",
     "product":{"id":"itm_1","name":"Примерен хербицид"},
     "doseUnit":{"id":"unt_1","symbol":"л/дка","name":"литра на декар"},
     "waterRateUnit":null,
     "parcel":{"id":"par_1","name":"SYNTH-1","areaHa":\(areaHa)},
     "completedBy":null}
    """
}

private func detailJSON(lines: [String], assignee: String? = "usr_operator") -> String {
    let assigneeJSON = assignee.map { "\"\($0)\"" } ?? "null"
    return """
    {"task":{"id":"tsk_1","tenantId":"ten_x","key":"FT-1","title":"Пръскане","type":"FIELD_OPERATION",
             "status":"IN_PROGRESS","assigneeUserId":\(assigneeJSON),
             "createdAt":"2026-10-03T06:30:00.000Z","updatedAt":"2026-10-03T06:30:00.000Z"},
     "lines":[\(lines.joined(separator: ","))],
     "location":{"id":"loc_1","name":"Synthetic Land","boundsJson":null},
     "parcels":[],
     "progress":{"total":\(lines.count),"done":0}}
    """
}

private func decodeDetail(_ json: String) async throws -> FieldOperationDetail {
    try await FieldOperationAPI.decodeDetail(from: Data(json.utf8))
}

private func line(
    _ id: String = "opl_1", status: OperationLineStatus = .pending, version: Int? = 3,
    parcel: String = "SYNTH-1"
) -> OperationLine {
    OperationLine(
        id: id, status: status, version: version, doseValue: WireDecimal(Decimal(string: "0.25")!),
        product: .init(id: "itm_1", name: "Примерен хербицид"),
        doseUnit: .init(id: "unt_1", symbol: "л/дка", name: "литра на декар"),
        parcel: .init(id: "par_\(id)", name: parcel, areaHa: WireDecimal(Decimal(string: "32.478")!)),
        completedAt: nil)
}

private func job(_ lines: [OperationLine], assignee: String? = "usr_operator") -> FieldOperationDetail {
    FieldOperationDetail(
        task: .init(id: "tsk_1", key: "FT-1", assigneeUserId: assignee, status: .inProgress),
        lines: lines)
}

// MARK: - Decoding

final class OperationLineDecodingTests: XCTestCase {

    /// The route's own shape, through the app's own decode.
    func testALineDecodesWithItsVersion() async throws {
        let detail = try await decodeDetail(detailJSON(lines: [lineJSON()]))
        let first = try XCTUnwrap(detail.lines.first)
        XCTAssertEqual(first.id, "opl_1")
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(first.version, 3, "the lock's version was not read with the line")
        XCTAssertEqual(first.product.name, "Примерен хербицид")
        XCTAssertEqual(first.doseUnit.symbol, "л/дка")
        XCTAssertEqual(first.parcel.name, "SYNTH-1")
        XCTAssertEqual(detail.task.assigneeUserId, "usr_operator")
        XCTAssertEqual(detail.task.key, "FT-1")
    }

    /// Version 0 — a line never touched — is a version, not an absence.
    func testVersionZeroIsAVersion() async throws {
        let detail = try await decodeDetail(detailJSON(lines: [lineJSON(version: "\"version\":0,")]))
        let first = try XCTUnwrap(detail.lines.first)
        XCTAssertEqual(first.version, 0)
        let row = LineState(line: first, waiting: nil, conflict: nil, refused: [])
        XCTAssertEqual(FieldOperationRules.actions(for: row, mayMark: true), [.done, .skipped])
    }

    /// The spec does not promise `version`. Without it the job still shows —
    /// and the line offers NO button, because a mark it could not guard would
    /// be the silent overwrite #138 forbids.
    func testALineWithoutAVersionShowsButCannotBeMarked() async throws {
        let detail = try await decodeDetail(detailJSON(lines: [lineJSON(version: nil)]))
        let first = try XCTUnwrap(detail.lines.first)
        XCTAssertNil(first.version)
        let row = LineState(line: first, waiting: nil, conflict: nil, refused: [])
        XCTAssertEqual(FieldOperationRules.actions(for: row, mayMark: true), [])
    }

    /// Decimal columns arrive as STRINGS here; a number is read too.
    func testTheDoseAndTheAreaReadAsDecimalStringsAndShowInBulgarian() async throws {
        let detail = try await decodeDetail(detailJSON(lines: [lineJSON()]))
        let first = try XCTUnwrap(detail.lines.first)
        XCTAssertEqual(first.doseText, "0,25")
        XCTAssertEqual(first.area?.text, "324,78 дка", "hectares on the wire, decares on screen")

        let numeric = try await decodeDetail(detailJSON(lines: [lineJSON(areaHa: "5")]))
        XCTAssertEqual(numeric.lines.first?.area?.text, "50 дка")
        let none = try await decodeDetail(detailJSON(lines: [lineJSON(areaHa: "null")]))
        XCTAssertNil(none.lines.first?.area)
    }

    /// A status this build does not know costs that line its label — never
    /// the job — and offers nothing to press.
    func testAnUnknownStatusIsTolerated() async throws {
        let detail = try await decodeDetail(detailJSON(lines: [lineJSON(status: "PARTIAL"), lineJSON(id: "opl_2")]))
        XCTAssertEqual(detail.lines.map(\.status), [.unknown, .pending])
        let row = LineState(line: detail.lines[0], waiting: nil, conflict: nil, refused: [])
        XCTAssertEqual(FieldOperationRules.actions(for: row, mayMark: true), [])
    }

    /// The labels are the web's `ag.status.operationParcel`, verbatim.
    func testTheLabelsAreTheWebs() {
        XCTAssertEqual(OperationLineStatus.pending.label, "Чакащо")
        XCTAssertEqual(OperationLineStatus.done.label, "Готово")
        XCTAssertEqual(OperationLineStatus.skipped.label, "Пропуснато")
        XCTAssertTrue(OperationLineStatus.done.isComplete)
        XCTAssertTrue(OperationLineStatus.skipped.isComplete, "a skip is progress, by the spec")
        XCTAssertFalse(OperationLineStatus.pending.isComplete)
    }
}

// MARK: - The wire

final class LineMarkWireTests: XCTestCase {

    private func source(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The body is `{status}` and nothing else — no `note`, whose explicit
    /// null would CLEAR a target note somebody else wrote.
    func testTheBodyIsTheStatusAlone() async throws {
        let body = try await FieldOperationAPI.body(.skipped)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json["status"] as? String, "SKIPPED")
    }

    func testTheMarkGoesToTheLineNotTheParcel() {
        let request = FieldOperationAPI.MarkRequest(taskID: "tsk_7", lineID: "opl_9", body: Data(), seenVersion: 2)
        XCTAssertEqual(request.path, "/api/t/\(Config.tenantSlug)/field-operations/tsk_7/parcels/opl_9")
    }

    /// THE If-Match. `patchRaw` takes the version as a non-optional Int and
    /// sends it through `APIClient.ifMatch` — the bare integer — with NO
    /// idempotency key. Read from the source: there is no URLProtocol seam
    /// in this suite, and the header is decided here, not by a caller.
    func testTheMarkSendsTheVersionAsABareIfMatchAndNoKey() throws {
        XCTAssertEqual(APIClient.ifMatch(3), "3")
        XCTAssertFalse(APIClient.ifMatch(3).contains("\""), "a quoted tag")
        XCTAssertFalse(APIClient.ifMatch(3).hasPrefix("W/"), "a weak tag is a 400 since agri-saas#1255")

        let text = source("Agrent/API/APIClient.swift")
        guard let start = text.range(of: "func patchRaw(_ path: String, body: Data, ifMatch version: Int)"),
              let end = text[start.upperBound...].range(of: "\n    }\n") else {
            return XCTFail("positive control: patchRaw is where this expects it, with a non-optional version")
        }
        let body = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("method: \"PATCH\""), String(body))
        XCTAssertTrue(body.contains("ifMatch: Self.ifMatch(version)"), "the version is not the If-Match")
        XCTAssertTrue(body.contains("idempotencyKey: nil"), "a key the route does not read reads as protection")

        // And the live mark and the replay both go through it.
        XCTAssertTrue(source("Agrent/API/FieldOperationAPI.swift")
            .contains("APIClient.shared.patchRaw("), "the live mark bypasses the guarded PATCH")
        XCTAssertTrue(source("Agrent/Core/OutboxStore.swift")
            .contains("APIClient.shared.patchRaw(path, body: item.payload, ifMatch: seenVersion)"),
                      "the replay does not send the version it saw")
    }

    /// The 409 this route sends — versions under `error.details`, plus a
    /// `currentStatus` the journal's lacks — reads as `.conflict` with the
    /// server's version, never from the body root.
    func testTheRoutes409ReadsAsAConflictWithTheServersVersion() {
        let body = #"""
        {"error":{"code":"STALE_DATA","message":"This job changed while you were offline.",
         "requestId":"req_1","details":{"currentVersion":4,"currentStatus":"SKIPPED","expectedVersion":3}}}
        """#
        guard case .conflict(let current, let expected) = APIClient.conflict(from: Data(body.utf8)) else {
            return XCTFail("a 409 did not become .conflict")
        }
        XCTAssertEqual(current, 4)
        XCTAssertEqual(expected, 3)
        XCTAssertEqual(FieldOperationRules.failure(APIClient.conflict(from: Data(body.utf8))),
                       .conflict(currentVersion: 4))
    }

    /// A landed mark's answer, read leniently: the version to sync to and
    /// whether the job is finished. Unreadable is not a failure — it landed.
    func testALandedAnswerIsReadLeniently() {
        let answer = #"{"success":true,"resolved":true,"application":null,"version":4}"#
        XCTAssertEqual(FieldOperationAPI.landed(from: Data(answer.utf8)),
                       .init(version: 4, resolved: true))
        let replay = #"{"success":true,"resolved":false,"application":null,"version":6,"alreadyApplied":true}"#
        XCTAssertEqual(FieldOperationAPI.landed(from: Data(replay.utf8)),
                       .init(version: 6, resolved: false))
        XCTAssertEqual(FieldOperationAPI.landed(from: Data("<html>".utf8)),
                       .init(version: nil, resolved: false))
    }

    /// What a failed tap becomes. The 409 first: it is neither retriable nor
    /// a refusal.
    func testWhatAFailedTapBecomes() {
        XCTAssertEqual(FieldOperationRules.failure(
            APIClient.APIError.conflict(currentVersion: 9, expectedVersion: 8)), .conflict(currentVersion: 9))
        XCTAssertEqual(FieldOperationRules.failure(URLError(.notConnectedToInternet)), .keep)
        XCTAssertEqual(FieldOperationRules.failure(URLError(.timedOut)), .keep,
                       "a timeout may have landed — the lock makes the replay safe")
        XCTAssertEqual(FieldOperationRules.failure(
            APIClient.APIError.http(status: 503, code: nil, message: nil)), .keep)
        XCTAssertEqual(FieldOperationRules.failure(
            APIClient.APIError.http(status: 429, code: "RATE_LIMITED", message: nil)), .keep)
        guard case .refused(let text) = FieldOperationRules.failure(
            APIClient.APIError.http(status: 403, code: "OPERATION_NOT_ASSIGNED_TO_YOU",
                                    message: "You can only update field operations assigned to you."))
        else { return XCTFail("a 403 was not a refusal") }
        XCTAssertEqual(text, "Можете да отбелязвате само задания, възложени на вас. Потърсете "
                       + "отговорника за това задание.", "the web's markForbidden, verbatim")
    }
}

// MARK: - The rules

final class FieldOperationRulesTests: XCTestCase {

    private func me(_ role: String?, id: String = "usr_me") -> CurrentUser {
        CurrentUser(id: id, name: nil, email: nil, role: role)
    }

    /// The route's rule: `canWrite`, or the job's assignee without it.
    func testWhoMayMark() {
        for role in ["OWNER", "ADMIN", "EDITOR"] {
            XCTAssertTrue(FieldOperationRules.mayMark(me: me(role), assigneeUserID: "someone_else"), role)
        }
        for role in ["MECHANISATOR", "READER", "AUDITOR"] {
            XCTAssertFalse(FieldOperationRules.mayMark(me: me(role), assigneeUserID: "someone_else"),
                           "\(role) may not mark a colleague's job")
            XCTAssertTrue(FieldOperationRules.mayMark(me: me(role), assigneeUserID: "usr_me"),
                          "the assigned \(role) may mark their own job")
        }
        XCTAssertFalse(FieldOperationRules.mayMark(me: me("MECHANISATOR"), assigneeUserID: nil),
                       "an unassigned job is not the operator's")
    }

    /// FAILS OPEN on a role this build does not know — the house pattern —
    /// and CLOSED with nobody known: a queued mark needs an owner.
    func testTheGateFailsOpenOnARoleAndClosedOnNobody() {
        XCTAssertTrue(FieldOperationRules.mayMark(me: me(nil), assigneeUserID: nil))
        XCTAssertTrue(FieldOperationRules.mayMark(me: me("SOMETHING_NEW"), assigneeUserID: nil))
        XCTAssertFalse(FieldOperationRules.mayMark(me: nil, assigneeUserID: "usr_me"))
    }

    /// The web's buttons, from what the line SHOWS.
    func testTheActionsAreTheWebs() {
        func actions(_ status: OperationLineStatus, mayMark: Bool = true) -> [OperationLineStatus] {
            FieldOperationRules.actions(
                for: LineState(line: line(status: status), waiting: nil, conflict: nil, refused: []),
                mayMark: mayMark)
        }
        XCTAssertEqual(actions(.pending), [.done, .skipped])
        XCTAssertEqual(actions(.done), [.pending])
        XCTAssertEqual(actions(.skipped), [.pending])
        XCTAssertEqual(actions(.pending, mayMark: false), [], "the gate hides every button")
        XCTAssertEqual(FieldOperationText.verb(.done), "Готово")
        XCTAssertEqual(FieldOperationText.verb(.skipped), "Пропусни")
        XCTAssertEqual(FieldOperationText.verb(.pending), "Отвори отново")
    }

    private func queued(_ lineID: String, _ status: OperationLineStatus, task: String = "tsk_1",
                        at seconds: TimeInterval = 0) -> PendingOperation {
        .mark(PendingOperation.LineMark(taskID: task, lineID: lineID, status: status.rawValue, seenVersion: 3),
              ownerUserID: "usr_me", summary: "x", payload: Data(), reason: nil,
              at: Date(timeIntervalSince1970: 1_900_000_000 + seconds))
    }

    /// A queued mark shows as the status it will have; a conflict offers no
    /// button (it waits for the operator's choice); a refusal is kept beside
    /// the line; another task's marks are not this task's.
    func testRowsOverlayThisTasksQueuedMarks() {
        var conflicted = queued("opl_2", .done)
        conflicted.conflict = .init(currentVersion: 5, at: Date())
        var refused = queued("opl_3", .skipped)
        refused.isRefused = true
        let rows = FieldOperationRules.rows(
            lines: [line("opl_1"), line("opl_2"), line("opl_3"), line("opl_4")],
            pending: [queued("opl_1", .done), conflicted, refused, queued("opl_4", .done, task: "tsk_other")],
            taskID: "tsk_1")

        XCTAssertEqual(rows.map(\.shown), [.done, .pending, .pending, .pending])
        XCTAssertNotNil(rows[0].waiting)
        XCTAssertEqual(FieldOperationRules.actions(for: rows[0], mayMark: true), [.pending],
                       "a queued «Готово» is reopened like a landed one")
        XCTAssertEqual(FieldOperationRules.actions(for: rows[1], mayMark: true), [])
        XCTAssertEqual(rows[2].refused.count, 1)
        XCTAssertNil(rows[3].waiting, "another task's mark was laid over this one's line")
    }

    /// The newest unsent mark wins should two ever coexist.
    func testTheNewestQueuedMarkIsShown() {
        let rows = FieldOperationRules.rows(
            lines: [line("opl_1")],
            pending: [queued("opl_1", .done, at: 1), queued("opl_1", .skipped, at: 2)],
            taskID: "tsk_1")
        XCTAssertEqual(rows.first?.shown, .skipped)
    }

    /// Counted from what the lines show — a queued mark included, a skip as
    /// progress — as the web's offline panel counts it.
    func testProgressCountsWhatTheLinesShow() {
        let rows = FieldOperationRules.rows(
            lines: [line("opl_1"), line("opl_2", status: .done), line("opl_3", status: .skipped)],
            pending: [queued("opl_1", .done)], taskID: "tsk_1")
        let progress = FieldOperationRules.progress(rows)
        XCTAssertEqual(progress.done, 3)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(FieldOperationText.progress(done: 2, total: 3), "2 / 3 парцела завършени")
    }

    /// Re-read when a mark LEFT the outbox or was parked — not when one joined.
    func testWhenTheOutboxMeansTheJobShouldBeReRead() {
        let a = FieldOperationRules.Queued(id: "a", conflicted: false)
        let b = FieldOperationRules.Queued(id: "b", conflicted: false)
        XCTAssertFalse(FieldOperationRules.reloadNeeded(from: [a], to: [a, b]), "a mark joined")
        XCTAssertTrue(FieldOperationRules.reloadNeeded(from: [a, b], to: [b]), "a mark was sent")
        XCTAssertTrue(FieldOperationRules.reloadNeeded(
            from: [a], to: [.init(id: "a", conflicted: true)]), "a mark was parked")
        XCTAssertFalse(FieldOperationRules.reloadNeeded(from: [], to: []))
    }

    /// «Запазено на телефона» goes when the mark stops waiting — sent or
    /// parked — rather than sitting under a line that is now on the server.
    /// The other notices stay until the next tap; none shows on another line.
    func testAKeptNoticeLastsOnlyWhileItsMarkWaits() {
        let waiting = LineState(line: line("opl_1"), waiting: queued("opl_1", .done), conflict: nil, refused: [])
        let sent = LineState(line: line("opl_1", status: .done), waiting: nil, conflict: nil, refused: [])
        let kept = FieldOperationStore.Notice(lineID: "opl_1", kind: .kept, text: FieldOperationText.kept)
        XCTAssertEqual(FieldOperationRules.visibleNotice(kept, for: waiting), kept)
        XCTAssertNil(FieldOperationRules.visibleNotice(kept, for: sent), "the phone still claims to hold it")

        let refused = FieldOperationStore.Notice(lineID: "opl_1", kind: .refused, text: "x.")
        XCTAssertEqual(FieldOperationRules.visibleNotice(refused, for: sent), refused)
        let cancelled = FieldOperationStore.Notice(lineID: "opl_1", kind: .cancelled,
                                                   text: FieldOperationText.cancelledOnPhone)
        XCTAssertEqual(FieldOperationRules.visibleNotice(cancelled, for: sent), cancelled)
        let elsewhere = LineState(line: line("opl_2"), waiting: nil, conflict: nil, refused: [])
        XCTAssertNil(FieldOperationRules.visibleNotice(refused, for: elsewhere))
    }

    func testAQueuedMarkIsNamedByTaskParcelAndStatus() {
        XCTAssertEqual(FieldOperationRules.summary(taskKey: "FT-1", parcel: "SYNTH-1", status: .done),
                       "FT-1 · SYNTH-1 · Готово")
        XCTAssertEqual(FieldOperationRules.summary(taskKey: nil, parcel: "SYNTH-1", status: .pending),
                       "SYNTH-1 · Чакащо", "a task with no key still names the line")
    }

    /// Every sentence a person reads here is Bulgarian and ends as one.
    func testTheWordsAreBulgarianSentences() {
        for text in [FieldOperationText.kept, FieldOperationText.cancelledOnPhone,
                     FieldOperationText.conflictLive, FieldOperationText.conflictDescription("x"),
                     FieldOperationText.keepMineUnavailable, FieldOperationText.refusedQueued(.done),
                     FieldOperationText.notPermitted, FieldOperationText.noVersion] {
            XCTAssertTrue(text.unicodeScalars.contains { $0.value >= 0x400 && $0.value <= 0x4FF }, text)
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }
}

// MARK: - The store, every outcome of a tap

/// Nothing sent: the read, the write and the body are closures, the outbox
/// a private directory owned by a fake identity.
@MainActor
final class FieldOperationStoreTests: XCTestCase {

    private let owner = "usr_me"
    private var directories: [String] = []

    override func tearDown() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in directories {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        directories = []
    }

    /// What the store asked of the network.
    private final class Network {
        var marks: [FieldOperationAPI.MarkRequest] = []
        var answer: (FieldOperationAPI.MarkRequest) throws -> FieldOperationAPI.Landed = { _ in
            .init(version: nil, resolved: false)
        }
        var reads: [Bool] = []
        /// What a read publishes, in order.
        var publishes: [LoadState<FieldOperationDetail>] = []
    }

    private func makeOutbox() -> (OutboxStore, PendingOperations) {
        let name = "FieldOperationStore-\(UUID().uuidString)"
        directories.append(name)
        let queue = PendingOperations(directoryName: name)
        let owner = owner
        // The DRAIN never sends here: a test that queues must not see it go.
        let outbox = OutboxStore(queue: queue, currentOwner: { owner }, identify: {},
                                 send: { _ in throw URLError(.notConnectedToInternet) })
        return (outbox, queue)
    }

    private func makeStore(_ network: Network, outbox: OutboxStore) -> FieldOperationStore {
        FieldOperationStore(
            taskID: "tsk_1", taskKey: "FT-1",
            fetch: { _, showCachedFirst, publish in
                network.reads.append(showCachedFirst)
                for state in network.publishes { publish(state) }
            },
            send: { request in
                network.marks.append(request)
                return try network.answer(request)
            },
            encode: { status in Data(#"{"status":"\#(status.rawValue)"}"#.utf8) },
            outbox: outbox)
    }

    private let me = CurrentUser(id: "usr_me", name: nil, email: nil, role: "OWNER")

    private func loaded(_ store: FieldOperationStore, _ network: Network, _ lines: [OperationLine]) async {
        network.publishes = [.loaded(job(lines), .fresh)]
        await store.load()
    }

    // MARK: landed

    /// A landed «Готово»: the If-Match was the version READ, the row takes
    /// the server's answer, the phone's unsent mark for the line goes, the
    /// job is re-read past the cache — and the person feels it.
    func testALandedDoneSyncsTheLineAndPlaysSuccess() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        await queue.enqueue(.mark(
            .init(taskID: "tsk_1", lineID: "opl_1", status: "SKIPPED", seenVersion: 3),
            ownerUserID: owner, summary: "x", payload: Data(), reason: nil))
        network.answer = { _ in .init(version: 4, resolved: false) }
        network.publishes = []   // the re-read finds no network

        await store.mark(line(version: 3), as: .done, by: me)

        XCTAssertEqual(network.marks.map(\.seenVersion), [3], "the If-Match was not the version read")
        XCTAssertEqual(network.marks.first?.lineID, "opl_1")
        XCTAssertEqual(store.state.value?.lines.first?.status, .done)
        XCTAssertEqual(store.state.value?.lines.first?.version, 4, "the next tap would assert a stale version")
        let left = await queue.all()
        XCTAssertTrue(left.isEmpty, "a stale queued mark would replay into a 409 against this one")
        XCTAssertEqual(network.reads.last, false, "the re-read showed the pre-mark cache first")
        XCTAssertEqual(store.feedback.feedback, .success)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.busyLineID)
    }

    /// The re-read after a landed mark fails and falls back to the CACHE,
    /// which predates the mark. The line must not flip back.
    func testAStaleReReadDoesNotUndoALandedMark() async {
        let network = Network()
        let (outbox, _) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in .init(version: 4, resolved: false) }
        network.publishes = [.loaded(job([line(version: 3)]), .stale(since: Date()))]

        await store.mark(line(version: 3), as: .skipped, by: me)
        XCTAssertEqual(store.state.value?.lines.first?.status, .skipped)
        XCTAssertEqual(store.state.value?.lines.first?.version, 4)

        // A FRESH answer still replaces it — the rule is not "never reload".
        network.publishes = [.loaded(job([line(status: .done, version: 7)]), .fresh)]
        await store.load()
        XCTAssertEqual(store.state.value?.lines.first?.version, 7)
    }

    /// THE SLOW-CONNECTION RACE. The screen's opening read shows the cache
    /// and goes to the network; the operator marks from the cached copy; the
    /// mark lands and its re-read answers; THEN the opening read's network
    /// answer arrives — fresh, and from before the mark. It is disowned.
    func testAReadAskedBeforeAWriteCannotUndoIt() async {
        let (outbox, _) = makeOutbox()
        var held: (@MainActor @Sendable (LoadState<FieldOperationDetail>) -> Void)?
        var reads = 0
        let store = FieldOperationStore(
            taskID: "tsk_1", taskKey: "FT-1",
            fetch: { _, _, publish in
                reads += 1
                if reads == 1 {
                    // The cache now; the network answer later.
                    publish(.loaded(job([line(version: 3)]), .stale(since: Date())))
                    held = publish
                } else {
                    publish(.loaded(job([line(status: .done, version: 4)]), .fresh))
                }
            },
            send: { _ in .init(version: 4, resolved: false) },
            encode: { _ in Data() },
            outbox: outbox)
        await store.load()
        await store.mark(line(version: 3), as: .done, by: me)
        XCTAssertEqual(store.state.value?.lines.first?.version, 4, "positive control: the mark landed")

        held?(.loaded(job([line(version: 3)]), .fresh))
        XCTAssertEqual(store.state.value?.lines.first?.status, .done, "the line flipped back")
        XCTAssertEqual(store.state.value?.lines.first?.version, 4,
                       "the next tap would assert a version the server has left behind")
    }

    /// The same race when the re-read after the mark finds NO network: it
    /// falls back to the pre-mark cache (ignored — stale), so no newer fresh
    /// answer is on screen to outrank the opening read's late one. Only the
    /// write disowning every read asked before it keeps the line as it is.
    func testAReadAskedBeforeAWriteCannotUndoItWhenTheReReadFails() async {
        let (outbox, _) = makeOutbox()
        var held: (@MainActor @Sendable (LoadState<FieldOperationDetail>) -> Void)?
        var reads = 0
        let store = FieldOperationStore(
            taskID: "tsk_1", taskKey: "FT-1",
            fetch: { _, _, publish in
                reads += 1
                // Every answer is the pre-mark line: the cache, twice.
                publish(.loaded(job([line(version: 3)]), .stale(since: Date())))
                if reads == 1 { held = publish }
            },
            send: { _ in .init(version: 4, resolved: false) },
            encode: { _ in Data() },
            outbox: outbox)
        await store.load()
        await store.mark(line(version: 3), as: .done, by: me)
        XCTAssertEqual(store.state.value?.lines.first?.version, 4, "positive control: the mark landed")

        held?(.loaded(job([line(version: 3)]), .fresh))
        XCTAssertEqual(store.state.value?.lines.first?.status, .done, "the line flipped back")
        XCTAssertEqual(store.state.value?.lines.first?.version, 4)
    }

    /// Skip and reopen land silently: #155 has no tap.
    func testSkipAndReopenPlayNothing() async {
        let network = Network()
        let (outbox, _) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        await store.mark(line(version: 3), as: .skipped, by: me)
        XCTAssertNil(store.feedback.feedback)
        await store.mark(line(status: .done, version: 4), as: .pending, by: me)
        XCTAssertNil(store.feedback.feedback)
        XCTAssertEqual(network.marks.count, 2)
    }

    /// The last line marked finishes the job: the task above is re-read.
    func testAMarkThatFinishesTheJobSaysSo() async {
        let network = Network()
        let (outbox, _) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in .init(version: 4, resolved: true) }
        await store.mark(line(version: 3), as: .done, by: me)
        XCTAssertEqual(store.finishedJob, 1)
    }

    // MARK: 409

    /// THE REQUIREMENT (#138): a 409 on the tap is said in Bulgarian, the job
    /// is re-read, and NOTHING is overwritten — not by a retry, not by a
    /// queued copy.
    func testAConflictOnTheTapIsSaidReloadedAndNeverOverwritten() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in throw APIClient.APIError.conflict(currentVersion: 5, expectedVersion: 3) }
        network.publishes = [.loaded(job([line(status: .skipped, version: 5)]), .fresh)]

        await store.mark(line(version: 3), as: .done, by: me)

        XCTAssertEqual(network.marks.count, 1, "a conflict was retried")
        XCTAssertEqual(store.notice?.kind, .conflict)
        XCTAssertEqual(store.notice?.text, FieldOperationText.conflictLive)
        XCTAssertEqual(store.notice?.lineID, "opl_1")
        XCTAssertEqual(store.feedback.feedback, .warning)
        XCTAssertEqual(store.state.value?.lines.first?.status, .skipped, "the job was not re-read")
        XCTAssertEqual(store.state.value?.lines.first?.version, 5)
        let queued = await queue.all()
        XCTAssertTrue(queued.isEmpty, "a conflict was queued to replay over the other change")
    }

    // MARK: no signal

    /// No signal: QUEUED with the version it SAW, owned, named — and a
    /// «Готово» kept on the phone is a success (#155: the device holds it).
    func testNoSignalQueuesTheMarkWithTheVersionItSaw() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in throw URLError(.notConnectedToInternet) }

        await store.mark(line(version: 3), as: .done, by: me)

        let queued = await queue.all()
        XCTAssertEqual(queued.count, 1)
        let item = queued[0]
        XCTAssertEqual(item.lineMark, .init(taskID: "tsk_1", lineID: "opl_1", status: "DONE", seenVersion: 3))
        XCTAssertEqual(item.ownerUserID, owner)
        XCTAssertEqual(String(data: item.payload, encoding: .utf8), #"{"status":"DONE"}"#,
                       "the queued bytes are not the ones the live attempt sent")
        XCTAssertEqual(item.payload, network.marks.first?.body)
        XCTAssertEqual(item.parcelSummary, "FT-1 · SYNTH-1 · Готово")
        XCTAssertEqual(store.notice?.kind, .kept)
        XCTAssertEqual(store.feedback.feedback, .success)
        XCTAssertEqual(OutboxStore.replay(for: item),
                       .mark(path: FieldOperationAPI.linePath(taskID: "tsk_1", lineID: "opl_1"), seenVersion: 3))
    }

    /// A 429 on the tap closes the OUTBOX's pause before the mark joins it —
    /// the live mark and the replay draw on one budget.
    func testA429QueuesTheMarkAndPausesTheQueue() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        defer { outbox.pause.reset() }
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in
            throw APIClient.APIError.http(status: 429, code: "RATE_LIMITED", message: nil, retryAfterSeconds: 40)
        }
        await store.mark(line(version: 3), as: .skipped, by: me)
        XCTAssertTrue(outbox.pause.isPaused)
        let queued = await queue.all()
        XCTAssertEqual(queued.count, 1)
        XCTAssertNil(store.feedback.feedback, "a skip kept on the phone plays nothing")
    }

    /// «Готово» then «Отвори отново» with no signal: the server still holds
    /// PENDING, so the queued mark is CANCELLED and nothing is sent — not a
    /// PENDING → PENDING write that bumps the version for nothing.
    func testUndoingAQueuedMarkCancelsItWithoutSending() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in throw URLError(.notConnectedToInternet) }
        await store.mark(line(version: 3), as: .done, by: me)
        let afterDone = await queue.all()
        XCTAssertEqual(afterDone.count, 1, "positive control: the «Готово» is queued")

        await store.mark(line(version: 3), as: .pending, by: me)
        XCTAssertEqual(network.marks.count, 1, "the undo was sent")
        let afterUndo = await queue.all()
        XCTAssertTrue(afterUndo.isEmpty, "the cancelled mark is still queued")
        XCTAssertEqual(store.notice?.kind, .cancelled)
        XCTAssertEqual(store.notice?.text, FieldOperationText.cancelledOnPhone)
    }

    // MARK: refused

    /// A 403 — not the assignee — is said in the web's words, played as a
    /// warning, and NOT queued: a refusal will be a refusal tomorrow.
    func testARefusalIsSaidAndNeverQueued() async {
        let network = Network()
        let (outbox, queue) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: 3)])
        network.answer = { _ in
            throw APIClient.APIError.http(status: 403, code: "OPERATION_NOT_ASSIGNED_TO_YOU", message: nil)
        }
        await store.mark(line(version: 3), as: .done, by: me)
        XCTAssertEqual(store.notice?.kind, .refused)
        XCTAssertTrue(store.notice?.text.hasPrefix("Можете да отбелязвате само задания") == true)
        XCTAssertEqual(store.feedback.feedback, .warning)
        let queued = await queue.all()
        XCTAssertTrue(queued.isEmpty)
    }

    // MARK: nothing sent

    /// No version, no mark; nobody known, no mark; one mark at a time.
    func testWhatIsNeverSent() async {
        let network = Network()
        let (outbox, _) = makeOutbox()
        let store = makeStore(network, outbox: outbox)
        await loaded(store, network, [line(version: nil)])
        await store.mark(line(version: nil), as: .done, by: me)
        XCTAssertTrue(network.marks.isEmpty, "a mark without a version is the unguarded overwrite")
        XCTAssertEqual(store.notice?.text, FieldOperationText.noVersion)

        await store.mark(line(version: 3), as: .done, by: nil)
        XCTAssertTrue(network.marks.isEmpty, "a mark with no owner to stamp")
    }
}
