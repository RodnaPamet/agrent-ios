import XCTest
@testable import Agrent

/// РЕКОЛТИ's and ПЛЕВЕЛИ's «Изтрий», its question and its five seconds of
/// «Отмени» (#541, owner 2026-11-06). Nothing here reaches the server: every
/// send is a closure that records what it was asked.
@MainActor
final class HistoryRemovalTests: XCTestCase {

    private func archive() async throws -> ParcelHistory {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "parcel-history", withExtension: "json"))
        return try await ParcelHistoryAPI.decodeHistory(from: Data(contentsOf: url))
    }

    private func me(canWrite: Bool = true) -> CurrentUser {
        CurrentUser(id: "u", name: nil, email: nil, role: nil,
                    permissions: CurrentUser.Permissions(canWrite: canWrite, canAdmin: false))
    }

    @MainActor
    private final class Calls {
        var log: [String] = []
        var refusal: Error?
    }

    private func removal(_ calls: Calls) -> HistoryRemoval {
        HistoryRemoval(parcelID: "par_holes", window: .seconds(600), send: { target in
            calls.log.append("\(target.kind) \(target.id)")
            if let refusal = calls.refusal { throw refusal }
        })
    }

    // MARK: - Who and what

    /// The routes' rule: anyone who may write.
    func testOfferedToWhoeverMayWrite() {
        XCTAssertTrue(HistoryRemoval.offered(to: me()))
        XCTAssertFalse(HistoryRemoval.offered(to: me(canWrite: false)), "a reader")
        XCTAssertFalse(HistoryRemoval.offered(to: nil))
    }

    /// The question and the bar name the entry as its row reads, in
    /// Bulgarian, with the web's sentence for what happens to it.
    func testTheWordsNameTheEntry() async throws {
        let history = try await archive()
        let season = HistoryRemoval.Target(try XCTUnwrap(history.cropSeasons.first))
        XCTAssertEqual(season.kind, .season)
        XCTAssertEqual(season.label, "2026, Пшеница, Добив 520 кг/дка")
        XCTAssertEqual(HistoryRemoval.confirmTitle(.season), "Сигурни ли сте, че искате да изтриете културата?")
        XCTAssertEqual(HistoryRemoval.removedText(season), "Изтрита култура: 2026, Пшеница, Добив 520 кг/дка")
        XCTAssertTrue(HistoryRemoval.confirmMessage(season).hasSuffix("Записът няма да се показва повече в архива."))

        let walk = HistoryRemoval.Target(try XCTUnwrap(history.weedObservations.first))
        XCTAssertEqual(walk.kind, .weeds)
        XCTAssertTrue(walk.label.contains("Балур"), walk.label)
        XCTAssertFalse(walk.label.contains("·"), "the separator would be read as «middle dot»")
        XCTAssertEqual(HistoryRemoval.confirmTitle(.weeds), "Сигурни ли сте, че искате да изтриете наблюдението?")
        XCTAssertTrue(HistoryRemoval.announcement(walk).contains("«Отмени»"))
    }

    func testThePathsAreTheEntriesOwn() {
        XCTAssertTrue(ParcelHistoryAPI.cropSeasonPath(parcelID: "p", seasonID: "s 1")
            .hasSuffix("/agro/parcels/p/crop-seasons/s%201"))
        XCTAssertTrue(ParcelHistoryAPI.weedObservationPath(parcelID: "p", observationID: "w")
            .hasSuffix("/agro/parcels/p/weed-observations/w"))
    }

    // MARK: - The five seconds

    func testUndoSendsNothing() async throws {
        let calls = Calls()
        let store = removal(calls)
        let season = HistoryRemoval.Target(try await archive().cropSeasons[0])
        store.remove(season)
        XCTAssertTrue(store.isHidden(season.id))
        store.undo()
        XCTAssertFalse(store.isHidden(season.id))
        XCTAssertEqual(calls.log, [])
    }

    func testTheWindowSendsItOnceToItsOwnRoute() async throws {
        let calls = Calls()
        let store = removal(calls)
        let walk = HistoryRemoval.Target(try await archive().weedObservations[0])
        store.remove(walk)
        await store.commit(walk.id)
        await store.commit(walk.id)
        XCTAssertEqual(calls.log, ["weeds \(walk.id)"])
        XCTAssertEqual(store.deletions, 1)
        store.archiveRead()
        XCTAssertFalse(store.isHidden(walk.id), "a fresh read no longer lists it")
    }

    func testARefusalBringsTheRowBack() async throws {
        let calls = Calls()
        calls.refusal = APIClient.APIError.http(status: 403, code: "FORBIDDEN", message: "Forbidden")
        let store = removal(calls)
        let season = HistoryRemoval.Target(try await archive().cropSeasons[0])
        store.remove(season)
        await store.commit(season.id)
        XCTAssertFalse(store.isHidden(season.id))
        XCTAssertTrue(store.showsFailure)
        XCTAssertTrue(UserMessage.isBulgarianSentence(store.failure ?? ""), store.failure ?? "")
        XCTAssertEqual(store.deletions, 0)
    }

    func testASecondDeleteSendsTheFirst() async throws {
        let calls = Calls()
        let store = removal(calls)
        let history = try await archive()
        let first = HistoryRemoval.Target(history.cropSeasons[0])
        let second = HistoryRemoval.Target(history.cropSeasons[1])
        store.remove(first)
        store.remove(second)
        XCTAssertEqual(store.undoable?.id, second.id)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(calls.log.first, "season \(first.id)")
    }
}
