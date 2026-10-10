import XCTest
@testable import Agrent

/// Новини's topics on the network (#231): nothing is saved before the
/// person's topics are read, one save runs at a time, and the newest list
/// is the one left on the server and on screen.
///
/// NOTHING HERE SENDS THE PUT. The store's network for the topics is two
/// injected closures, as `AdminStore`'s is — there is no URLProtocol seam in
/// `Tests/`, and every rule below is decided above the wire.
@MainActor
final class NewsStoreTests: XCTestCase {

    /// What the store sent, and how the server answers.
    private final class Wire {
        var read: () throws -> [String]? = { throw URLError(.notConnectedToInternet) }
        var sent: [[String]] = []
        var saveFails = false
        /// Run once, while the next save is on the wire.
        var duringSave: (() async -> Void)?
    }

    private func store(_ wire: Wire) -> NewsStore {
        NewsStore(
            readTopics: { try wire.read() },
            sendTopics: { tags in
                wire.sent.append(tags)
                let during = wire.duringSave
                wire.duringSave = nil
                await during?()
                if wire.saveFails { throw URLError(.notConnectedToInternet) }
                return tags.sorted()
            })
    }

    /// `chosen` is nil both for «never chose» and for a read that failed, so
    /// a flip after a failed read would save a list built from nothing over
    /// the topics the person keeps. Before a read, a flip does nothing.
    func testNothingIsSavedBeforeTheTopicsAreRead() async {
        let wire = Wire()
        let news = store(wire)
        await news.loadPreferences()
        XCTAssertFalse(news.preferencesRead)
        let said = news.preferencesReadError ?? ""
        XCTAssertTrue(said.hasPrefix("Избраните теми не са прочетени."), said)

        news.toggle("wheat")
        XCTAssertNil(news.chosen)
        XCTAssertNil(news.saving)
        XCTAssertEqual(wire.sent, [])

        // Positive control: once read, the same flip moves and is saved.
        wire.read = { ["subsidies"] }
        await news.loadPreferences()
        XCTAssertTrue(news.preferencesRead)
        XCTAssertNil(news.preferencesReadError)
        news.toggle("wheat")
        XCTAssertEqual(news.chosen, ["subsidies", "wheat"])
        await news.saving?.value
        XCTAssertEqual(wire.sent, [["subsidies", "wheat"]])
    }

    /// «Never chose» is an answer, not a failure: the switches work.
    func testNeverChoseIsARead() async {
        let wire = Wire()
        wire.read = { nil }
        let news = store(wire)
        await news.loadPreferences()
        XCTAssertTrue(news.preferencesRead)
        XCTAssertNil(news.chosen)

        news.toggle("wheat")
        await news.saving?.value
        XCTAssertEqual(wire.sent, [["wheat"]])
    }

    /// Flips in one turn are one save, of the list they leave.
    func testFlipsInOneTurnAreOneSave() async {
        let wire = Wire()
        wire.read = { [] }
        let news = store(wire)
        await news.loadPreferences()

        news.toggle("wheat")
        news.toggle("corn")
        news.toggle("wheat")
        await news.saving?.value
        XCTAssertEqual(wire.sent, [["corn"]])
        XCTAssertEqual(news.chosen, ["corn"])
    }

    /// A flip while a save is on the wire waits for it, then the newer list
    /// is written — and the first answer, which is older, is not put back
    /// on screen in between (the second save is of what was on screen).
    func testAFlipDuringASaveIsWrittenAfterIt() async {
        let wire = Wire()
        wire.read = { [] }
        let news = store(wire)
        await news.loadPreferences()

        wire.duringSave = { news.toggle("corn") }
        news.toggle("wheat")
        await news.saving?.value
        XCTAssertEqual(wire.sent, [["wheat"], ["corn", "wheat"]])
        XCTAssertEqual(news.chosen, ["corn", "wheat"])
    }

    /// A read that lands while a flip is being saved is older than the flip:
    /// it does not put the old list back on screen.
    func testAReadDoesNotUndoAFlipBeingSaved() async {
        let wire = Wire()
        wire.read = { ["subsidies"] }
        let news = store(wire)
        await news.loadPreferences()

        var onScreen: [String]?
        wire.duringSave = {
            await news.loadPreferences()
            onScreen = news.chosen
        }
        news.toggle("wheat")
        await news.saving?.value
        XCTAssertEqual(onScreen, ["subsidies", "wheat"])
        XCTAssertEqual(news.chosen, ["subsidies", "wheat"])
    }

    /// A save that fails keeps the choice on screen and says so; «Опитай
    /// пак» writes the whole list again and the message goes.
    func testAFailedSaveKeepsTheChoiceAndCanBeRetried() async {
        let wire = Wire()
        wire.read = { ["subsidies"] }
        wire.saveFails = true
        let news = store(wire)
        await news.loadPreferences()

        news.toggle("wheat")
        await news.saving?.value
        XCTAssertEqual(news.chosen, ["subsidies", "wheat"])
        let said = news.preferencesError ?? ""
        XCTAssertTrue(said.hasPrefix("Предпочитанията не са запазени."), said)

        wire.saveFails = false
        news.retrySave()
        await news.saving?.value
        XCTAssertNil(news.preferencesError)
        XCTAssertEqual(wire.sent, [["subsidies", "wheat"], ["subsidies", "wheat"]])
    }
}
