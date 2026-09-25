import XCTest
@testable import Agrent

/// What the parcel-history SCREENS claim, as opposed to what the data layer
/// holds.
///
/// ── Why these are worth tests at all ──
///
/// Every decision the owner made about this screen is a claim about text, and
/// every one of them has a failure mode that produces a perfectly valid string:
///
///   • a count that must be ABSENT while a cursor exists — because « 100+ »
///     reads as "more than 100", which is the one thing a cursor does not mean;
///   • a dose unit that must not leave a trailing space (shipped, once);
///   • a product name that must not leave a leading « · » (shipped, once, in
///     `LocationsView`, in front of a parcel count);
///   • "newest" that must mean `items.first` and never a sort;
///   • an empty section that must not offer a push to an empty list.
///
/// None of that can be seen by a compiler and none of it can be seen in a
/// diff. It can be seen here, which is why `ParcelHistoryLine`,
/// `ParcelHistoryCard` and `ParcelHistoryPaging` are values built outside the
/// views rather than `if` statements inside them.
///
/// ── The dates are all 11:00Z on purpose ──
///
/// A day-and-month rendered from an instant depends on the machine's time
/// zone, and this suite runs both on a phone set to Europe/Sofia and on CI.
/// 11:00Z is the same calendar day from UTC-11 through UTC+12, so a literal
/// month name is safe to assert. `Num.text` failed on CI alone last week for
/// exactly the opposite reason — a test that pinned something the machine
/// owned.
final class ParcelHistoryViewTests: XCTestCase {

    // MARK: - Fixtures

    private func decode<T: Decodable>(_ json: String, as type: T.Type) async throws -> T {
        try await APIClient.shared.decode(Data(json.utf8), as: type)
    }

    private func season(_ id: String, year: Int, crop: String = "Wheat",
                        sownAt: String? = nil) -> CropSeason {
        CropSeason(id: id, year: year, cropType: crop, notes: nil,
                   sownAtRaw: sownAt, harvestedAtRaw: nil)
    }

    /// Built by DECODING, not by an initialiser.
    ///
    /// `ParcelHistoryOperation` keeps `titleRaw` and `productNameRaw` private
    /// so that `title` and `productName` can be the `String.recorded` view of
    /// them — which also means there is no memberwise initialiser to reach
    /// from here. That is the right way round: these tests are about what
    /// arrives on the wire, and the wire is what they construct.
    private func operation(
        id: String = "op1",
        title: String = "Хербицид",
        productName: String = "Раундъп",
        doseValue: String = "2.5",
        doseUnit: String = "л/дка",
        completedAt: String? = "2026-05-03T11:00:00.000Z"
    ) async throws -> ParcelHistoryOperation {
        let completed = completedAt.map { "\"\($0)\"" } ?? "null"
        return try await decode("""
        {"id":"\(id)","taskId":"t1","operationType":"SPRAY","title":"\(title)",
         "completedAt":\(completed),"productName":"\(productName)",
         "doseValue":"\(doseValue)","doseUnit":"\(doseUnit)","targetNote":null}
        """, as: ParcelHistoryOperation.self)
    }

    private func observation(
        _ id: String = "wo1",
        keys: [String] = ["Sorghum halepense"],
        other: [String] = [],
        observedAt: String = "2026-06-11T11:00:00.000Z"
    ) -> WeedObservation {
        WeedObservation(id: id, weedKeys: keys, otherWeeds: other,
                        notes: nil, observedAtRaw: observedAt)
    }

    private func seasonSection(
        _ seasons: [CropSeason], cursor: String? = nil,
        isLoadingOlder: Bool = false, exhausted: Bool = false, failure: String? = nil
    ) -> ParcelHistoryStore.Section<CropSeason> {
        ParcelHistoryStore.Section(
            items: seasons, cursor: cursor, isLoadingOlder: isLoadingOlder,
            exhausted: exhausted, failure: failure)
    }

    private func card(_ section: ParcelHistoryStore.Section<CropSeason>) -> ParcelHistoryCard {
        ParcelHistoryCard(title: ParcelHistoryCopy.seasons, section: section,
                          line: { $0.historyLine })
    }

    // MARK: - The section names

    /// Pinned character by character, because they are the owner's words and
    /// because Cyrillic has Latin lookalikes — a «Р» typed as a «P» would look
    /// identical on screen, sort differently, and be read out by VoiceOver as
    /// an English letter.
    func testTheThreeSectionNamesAreExactlyTheOnesTheOwnerGave() {
        XCTAssertEqual(ParcelHistoryCopy.seasons, "РЕКОЛТИ")
        XCTAssertEqual(ParcelHistoryCopy.operations, "ДЕЙНОСТИ")
        XCTAssertEqual(ParcelHistoryCopy.weeds, "ПЛЕВЕЛИ")
    }

    // MARK: - The count, and its absence

    /// A count is only available for a section that arrived WHOLE, and a null
    /// cursor is what says so. Then it is exact and it is worth showing: it is
    /// the answer to "is this all of it", given without a control to tap.
    func testACompleteSectionShowsItsExactCount() {
        let complete = card(seasonSection(
            [season("a", year: 2026), season("b", year: 2025), season("c", year: 2024)],
            cursor: nil))
        XCTAssertEqual(complete.count, "3 записа")
    }

    /// Bulgarian nouns take a counting form after a numeral, and the automatic
    /// `^[…](inflect:)` markup cannot be used here — it is only processed when
    /// it reaches `Text` as a literal, and this string is built in a variable
    /// and also spoken by VoiceOver. `Plural` exists for that, and this is the
    /// assertion that this screen went through it.
    func testTheCountUsesTheBulgarianCountingForm() {
        XCTAssertEqual(card(seasonSection([season("a", year: 2026)])).count, "1 запис")
        XCTAssertEqual(
            card(seasonSection([season("a", year: 2026), season("b", year: 2025)])).count,
            "2 записа")
    }

    /// THE test on the card.
    ///
    /// The envelope carries no total — up to 100 rows and a cursor — so with a
    /// cursor in hand the only number available is "how many are loaded".
    /// Rendered as « 100+ » that reads as "more than 100", which is precisely
    /// what it does not mean: the server hands back a cursor for the last row
    /// of the page it just sent, so a section holding exactly 100 rows returns
    /// one too.
    ///
    /// So there is NO count, and no «+», no footnote and no explanatory band
    /// in its place. Making no claim beats a claim that needs a footnote.
    func testASectionWithACursorShowsNoCountAtAll() {
        let paged = card(seasonSection(
            [season("a", year: 2026), season("b", year: 2025)],
            cursor: "b3AxfDIwMjY="))

        XCTAssertNil(paged.count)

        // And the newest entry is still named: the card loses its count, not
        // its content.
        XCTAssertEqual(paged.newest?.text, "2026 · Пшеница")
        XCTAssertTrue(paged.isTappable)
    }

    /// The one case the rule leaves on the table, recorded so the next reader
    /// does not think it is a bug.
    ///
    /// `exhausted` can be true while the cursor is still non-nil: that is the
    /// empty-page ending, where the server answered a "load older" with
    /// nothing new and the cursor was never replaced. The section really is
    /// complete then, so a count would be TRUE — but the rule the owner gave
    /// names the cursor, and silence is not a false claim. Widening it is a
    /// decision for the owner, not for this file.
    func testAnExhaustedSectionWhoseCursorSurvivedStillMakesNoClaim() {
        var section = seasonSection([season("a", year: 2026)], cursor: "c1")
        section.appendOlder([], cursor: "c1")   // the page that carried nothing new

        XCTAssertTrue(section.exhausted)
        XCTAssertNotNil(section.cursor)
        XCTAssertNil(card(section).count)
    }

    // MARK: - Empty

    /// An empty section is NOT tappable, and says so in words rather than in a
    /// number. Pushing to an empty list is the same broken promise as a
    /// disabled button, and « 0 записа » beside «Няма записи» would be the
    /// same fact twice.
    func testAnEmptySectionSaysNyamaZapisiAndIsNotTappable() {
        let empty = card(seasonSection([], cursor: nil))

        XCTAssertNil(empty.newest)
        XCTAssertNil(empty.count)
        XCTAssertFalse(empty.isTappable)

        // What VoiceOver gets for it: the section's name and the fact, with
        // nothing implying there is anywhere to go.
        let spoken = A11y.sentence(
            [empty.title, empty.count] + (empty.newest?.parts ?? [ParcelHistoryCopy.emptySection]))
        XCTAssertEqual(spoken, "РЕКОЛТИ, Няма записи.")
    }

    /// A parcel imported yesterday has an empty archive, and that is an
    /// ordinary state rather than a failure. It collapses to ONE line — three
    /// cards each saying nothing is three pieces of furniture to tell the
    /// reader one thing.
    func testAnEmptyArchiveIsOneLineRatherThanThreeCards() async throws {
        let archive = ParcelHistoryStore.Archive(try await decode(#"""
        {"parcel":{"id":"p1","name":"Долен блок","cropType":null},
         "cropSeasons":[],"operations":[],"weedObservations":[],
         "cropSeasonsCursor":null,"operationsCursor":null,"weedObservationsCursor":null}
        """#, as: ParcelHistory.self))

        XCTAssertTrue(archive.isEmpty)
        XCTAssertEqual(ParcelHistoryCopy.emptyArchive,
                       "Няма записана история за този парцел.")

        // The three cards the screen does NOT draw in this state would each
        // have been empty and unreachable, which is what makes the one line
        // the right rendering rather than merely the shorter one.
        XCTAssertFalse(card(archive.seasons).isTappable)
        XCTAssertFalse(ParcelHistoryCard(title: ParcelHistoryCopy.operations,
                                         section: archive.operations,
                                         line: { $0.historyLine }).isTappable)
        XCTAssertFalse(ParcelHistoryCard(title: ParcelHistoryCopy.weeds,
                                         section: archive.weeds,
                                         line: { $0.historyLine }).isTappable)
    }

    // MARK: - Newest is the head of the list

    /// "Newest" is `items.first`, because the order is the SERVER'S: the store
    /// never sorts and `appendOlder` appends.
    func testTheNewestEntryIsTheHeadOfTheServersOrder() {
        let items = [season("a", year: 2026, crop: "Wheat"),
                     season("b", year: 2025, crop: "Maize")]
        XCTAssertEqual(card(seasonSection(items)).newest?.text, "2026 · Пшеница")
    }

    /// THE pin on D10, and it is deliberately hostile: the server's order is
    /// taken AS GIVEN even when a year out of place makes it look wrong.
    ///
    /// A catch crop is legal, a back-filled season is legal, and the server's
    /// `ORDER BY` is the one that matches the cursor. A client-side sort would
    /// interleave a newly loaded page into the rows already on screen — after
    /// which «Покажи по-стари» has stopped explaining itself, because what it
    /// added is no longer at the bottom.
    func testNothingIsSortedClientSideEvenWhenTheOrderLooksWrong() {
        var section = seasonSection(
            [season("a", year: 2024), season("b", year: 2026)], cursor: "c1")

        // As sent: 2024 first. A sort would put 2026 at the head and change
        // what the card claims.
        XCTAssertEqual(card(section).newest?.text, "2024 · Пшеница")

        // An older page appends at the BOTTOM, and the newest entry is
        // untouched by it.
        section.appendOlder([season("c", year: 2025)], cursor: nil)
        XCTAssertEqual(section.items.map(\.year), [2024, 2026, 2025])
        XCTAssertEqual(card(section).newest?.text, "2024 · Пшеница")
    }

    // MARK: - РЕКОЛТИ rows

    /// Wheat drilled in October 2025 is the 2026 harvest. A row that took its
    /// year from `sownAt` would file it under 2025, and most autumn cropping in
    /// Bulgaria with it — every row still plausible, only the per-year totals
    /// nonsense.
    func testASeasonRowLeadsWithTheHarvestYearAndNotTheSowingYear() throws {
        let autumn = season("a", year: 2026, sownAt: "2025-10-14T11:00:00.000Z")
        let line = autumn.historyLine

        XCTAssertEqual(line.lead, "2026")
        XCTAssertEqual(line.text, "2026 · Пшеница")

        // And the sowing really is in the previous calendar year, so the
        // assertion above is not accidentally agreeing with a derivation.
        let sownYear = Calendar(identifier: .gregorian)
            .component(.year, from: try XCTUnwrap(autumn.sownAt))
        XCTAssertEqual(sownYear, 2025)
    }

    /// A year is a LABEL, not a quantity: `String(year)` rather than a number
    /// formatter, which in `bg_BG` would group the digits and print « 2 026 ».
    func testASeasonRowShowsTheYearWithoutAGroupingSeparator() throws {
        let line = season("a", year: 2026).historyLine
        XCTAssertEqual(line.lead, "2026")
        XCTAssertFalse(try XCTUnwrap(line.lead).contains(" "))
        XCTAssertFalse(try XCTUnwrap(line.lead).contains("\u{00A0}"))
    }

    // MARK: - ДЕЙНОСТИ rows, and the four ways a part goes missing

    func testAnOperationRowShowsTheDayTheTitleTheProductAndTheDose() async throws {
        let spray = try await operation()
        let line = spray.historyLine

        XCTAssertEqual(line.text, "3 май · Хербицид")
        XCTAssertEqual(line.detailText, "Раундъп · 2,5 л/дка")

        // The date is the app's ONE date idiom, not `Date.formatted()` — the
        // device here reports en_BG and would render "3 May" from the same
        // format style. See `BgDate`.
        let completed = try XCTUnwrap(spray.completedAt)
        XCTAssertEqual(line.lead, BgDate.dayMonth(completed))
        XCTAssertFalse(line.text.contains("May"), line.text)
    }

    /// `title` is `line.task?.title ?? ''` on the server, so an empty string is
    /// a REAL shape and it means NOT RECORDED — and the row now says what KIND
    /// of work it was instead of leaving the slot bare.
    ///
    /// This asserted `headline == nil`, which was the honest rendering while
    /// nothing better existed. `productCategory` arrived on 2026-09-25 and
    /// `recordedKind` fills exactly this slot: such a row previously said
    /// nothing about what had been DONE to the field, only what was applied to
    /// it. Assert the fallback, not the gap.
    func testAnOperationWithNoTitleFallsBackToWhatKindItWas() async throws {
        let line = try await operation(title: "").historyLine

        XCTAssertEqual(line.headline, "Пръскане")
        XCTAssertEqual(line.text, "3 май · Пръскане")
        XCTAssertFalse(line.text.hasSuffix(" "), "«\(line.text)»")
    }

    /// AND NOTHING when neither says. No title, no `operationType`, no product
    /// category — the slot stays empty rather than inventing «Друга», which
    /// would be a classification the data does not make.
    func testAnOperationWithNoTitleAndNoKindLeavesTheSlotEmpty() async throws {
        let line = try await decode(#"""
        {"id":"x","taskId":"t","operationType":null,"title":"",
         "completedAt":"2026-05-03T11:00:00.000Z","productName":"Раундъп",
         "doseValue":"2.5","doseUnit":"л/дка","targetNote":null,
         "productCategory":null}
        """#, as: ParcelHistoryOperation.self).historyLine

        XCTAssertNil(line.headline)
        XCTAssertEqual(line.text, "3 май")
        XCTAssertFalse(line.text.contains("·"), "«\(line.text)»")
    }

    /// The category is the HARDER signal and the fallback uses it: a line whose
    /// operator recorded no type still names the work, retroactively, from what
    /// the product was.
    func testTheProductCategoryNamesTheWorkWhenNoTypeWasRecorded() async throws {
        let line = try await decode(#"""
        {"id":"x","taskId":"t","operationType":null,"title":"",
         "completedAt":null,"productName":"NPK","doseValue":"15",
         "doseUnit":"кг/дка","targetNote":null,"productCategory":"FERTILIZER"}
        """#, as: ParcelHistoryOperation.self).historyLine

        XCTAssertEqual(line.headline, "Торене")
    }

    /// A category that is not a kind of field work names nothing. `FUEL` and
    /// `HARVESTED_PRODUCE` are not applications to a parcel at all, and `OTHER`
    /// is not a classification — «Друга» there would be invented.
    func testACategoryThatIsNotFieldWorkNamesNothing() async throws {
        for category in ["FUEL", "HARVESTED_PRODUCE", "OTHER", "NEW_THING"] {
            let line = try await decode("""
            {"id":"x","taskId":"t","operationType":null,"title":"",
             "completedAt":null,"productName":"x","doseValue":"1",
             "doseUnit":"","targetNote":null,"productCategory":"\(category)"}
            """, as: ParcelHistoryOperation.self).historyLine
            XCTAssertNil(line.headline, category)
        }
    }

    /// The recorded type WINS over the derived category, even when they
    /// disagree. Correcting a farmer's own entry from a derived field is a
    /// bigger decision than a row label, and nobody has asked for it.
    func testWhatWasRecordedBeatsWhatWasDerived() async throws {
        let line = try await decode(#"""
        {"id":"x","taskId":"t","operationType":"SPRAY","title":"",
         "completedAt":null,"productName":"NPK","doseValue":"15",
         "doseUnit":"кг/дка","targetNote":null,"productCategory":"FERTILIZER"}
        """#, as: ParcelHistoryOperation.self).historyLine

        XCTAssertEqual(line.headline, "Пръскане", "recorded, not derived")
    }

    /// The mirror image, and the one this app has actually shipped: an absent
    /// `kind` left a LEADING « · » in front of a parcel count in
    /// `LocationsView`. Here an absent product must not leave one in front of
    /// the dose.
    func testAnOperationWithNoProductLeavesNoLeadingSeparatorBeforeTheDose() async throws {
        let line = try await operation(productName: "").historyLine

        XCTAssertEqual(line.details, ["2,5 л/дка"])
        XCTAssertEqual(line.detailText, "2,5 л/дка")
        XCTAssertFalse(line.detailText.hasPrefix("·"), "«\(line.detailText)»")
        XCTAssertFalse(line.detailText.hasPrefix(" "), "«\(line.detailText)»")
    }

    /// An empty `doseUnit` is the server saying NO UNIT WAS RECORDED — it falls
    /// back to `''` rather than to null, so it is a meaning and not a missing
    /// value. This shipped as a trailing space: invisible in a diff, visible in
    /// a right-aligned column.
    func testAnOperationWithNoUnitShowsTheNumberAloneWithNoTrailingSpace() async throws {
        let line = try await operation(doseUnit: "").historyLine

        XCTAssertEqual(line.detailText, "Раундъп · 2,5")
        XCTAssertFalse(line.detailText.hasSuffix(" "), "«\(line.detailText)»")
        XCTAssertFalse(line.detailText.contains("  "), "«\(line.detailText)»")
    }

    /// Whitespace is not something a farmer typed on purpose, and it renders
    /// identically to empty while defeating an `isEmpty` check.
    func testAWhitespaceOnlyTitleCountsAsNotRecorded() async throws {
        let line = try await operation(title: "   ").historyLine
        // Not recorded, so the kind stands in — same as an empty one.
        XCTAssertEqual(line.headline, "Пръскане")
    }

    /// `completedAt` is optional on the wire. No date, no date — and no
    /// placeholder standing in for one, which on a regulated record would be
    /// an invented uncertainty.
    func testAnOperationWithNoCompletionDateLeavesTheDateOut() async throws {
        let line = try await operation(completedAt: nil).historyLine

        XCTAssertNil(line.lead)
        XCTAssertEqual(line.text, "Хербицид")
        XCTAssertFalse(line.text.contains("·"), "«\(line.text)»")
    }

    /// All four parts absent at once. The dose survives, because `doseValue` is
    /// the one field that cannot collapse to an empty string — so the row is
    /// thin rather than blank, and it is still worth speaking.
    func testAnOperationWithNothingButItsDoseStillHasARowAndALabel() async throws {
        let line = try await operation(
            title: "", productName: "", doseValue: "1", doseUnit: "", completedAt: nil
        ).historyLine

        // «Пръскане» from the recorded type, because the title is not
        // recorded — the thinnest possible row still says what was done.
        XCTAssertEqual(line.text, "Пръскане")
        XCTAssertEqual(line.detailText, "1")
        XCTAssertFalse(line.isBlank)
        XCTAssertEqual(line.spoken, "Пръскане, 1.")
    }

    // MARK: - ПЛЕВЕЛИ rows

    /// The names are joined with ", " on the owner's instruction — and that is
    /// also the only separator here that is safe to speak, which is why the
    /// whole list is one part of the line rather than one part per weed.
    ///
    /// `displayNames` already renders a catalogue weed with its binomial and
    /// free text verbatim, and already puts the catalogue half first. Nothing
    /// in the view re-orders or re-translates it: the split between the halves
    /// is the SERVER'S.
    func testAWeedRowLeadsWithTheDayAndJoinsTheNamesWithCommas() {
        let seen = observation(keys: ["Sorghum halepense"], other: ["някакъв друг плевел"])
        let line = seen.historyLine

        XCTAssertEqual(line.lead, "11 юни")
        XCTAssertEqual(line.headline, "балур (Sorghum halepense), някакъв друг плевел")
        XCTAssertEqual(line.text, "11 юни · балур (Sorghum halepense), някакъв друг плевел")
    }

    /// A weed the catalogue does not carry renders as its binomial rather than
    /// as a blank or a wrong Bulgarian name — the catalogue is a relayed list
    /// this client cannot verify, so the fallback is the only safe direction.
    func testAWeedThisBuildDoesNotKnowStillNamesSomething() {
        let line = observation(keys: ["Lolium perenne"]).historyLine
        XCTAssertEqual(line.headline, "Lolium perenne")
    }

    // MARK: - What VoiceOver hears

    /// The separator is TYPOGRAPHY and must never reach the audio channel.
    /// `children: .combine` would have read it — "3 май middle dot Хербицид" —
    /// which is the defect `A11y` was written to end, and which shipped once in
    /// `JournalRow` where the screen said «21 септември» and VoiceOver said
    /// "21 September".
    func testASpokenRowIsBuiltFromValuesAndCarriesNoMiddleDot() async throws {
        let line = try await operation().historyLine

        XCTAssertEqual(line.spoken, "3 май, Хербицид, Раундъп, 2,5 л/дка.")
        XCTAssertFalse(line.spoken.contains("·"), line.spoken)
        XCTAssertTrue(line.spoken.hasSuffix("."), line.spoken)
    }

    /// A card is ONE stop, and it names its section, its count and its newest
    /// entry in that order — so a reader swiping through the screen hears what
    /// the card is before hearing what is on it.
    func testASpokenCardNamesItsSectionThenItsCountThenItsNewestEntry() {
        let subject = card(seasonSection(
            [season("a", year: 2026), season("b", year: 2025)], cursor: nil))
        let spoken = A11y.sentence([subject.title, subject.count] + (subject.newest?.parts ?? []))

        XCTAssertEqual(spoken, "РЕКОЛТИ, 2 записа, 2026, Пшеница.")
        XCTAssertFalse(spoken.contains("·"), spoken)
    }

    // MARK: - The end of a drill-in list

    /// A section that came whole in its first page offers NOTHING — no
    /// control, and no sentence explaining the absence of one. The card
    /// upstairs carries its exact count, which says the same thing better.
    func testNoPagingControlIsOfferedWhenTheSectionCameWhole() {
        XCTAssertEqual(
            ParcelHistoryPaging(seasonSection([season("a", year: 2026)], cursor: nil)),
            .nothing)
    }

    func testAPagingControlIsOfferedWhileACursorSurvives() {
        XCTAssertEqual(
            ParcelHistoryPaging(seasonSection([season("a", year: 2026)], cursor: "c1")),
            .button)
        XCTAssertEqual(ParcelHistoryCopy.loadOlder, "Покажи по-стари")
    }

    /// Per-section, because the three lists page independently: a spinner
    /// shared between them would claim the other two were busy.
    func testASectionInFlightShowsItsOwnSpinner() {
        let loading = seasonSection([season("a", year: 2026)], cursor: "c1",
                                    isLoadingOlder: true)
        XCTAssertEqual(ParcelHistoryPaging(loading), .spinner)

        // And the other two sections are unaffected — the store's flag is per
        // section and so is this.
        XCTAssertEqual(ParcelHistoryPaging(seasonSection([season("b", year: 2025)],
                                                         cursor: "c2")), .button)
    }

    /// A tap that makes the control silently vanish reads as a bug: the reader
    /// cannot tell "that was the end" from "that did not work". So the button
    /// is REPLACED rather than removed — but by WHICH sentence depends on
    /// whether the archive really is finished, and this test asserted the
    /// wrong one.
    ///
    /// It pinned `.end` for both endings, including the stale-cursor restart.
    /// That told a farmer his field had no earlier record when it did, on an
    /// agronomic archive, with the control gone so he could not ask again —
    /// and the test made it look deliberate.
    ///
    /// The cursor is what decides. Nil means the SERVER said there is nothing
    /// older, which is a claim about the archive. A surviving cursor means a
    /// page arrived carrying nothing new, which is either an exact-divide
    /// ending or a restart, and nothing here can tell those apart — so the
    /// sentence narrows to a claim about the screen.
    func testTheEndingSentenceMatchesWhichEndingItWas() {
        var ended = seasonSection([season("a", year: 2026)], cursor: "c1")
        ended.appendOlder([season("b", year: 2025)], cursor: nil)
        XCTAssertEqual(ParcelHistoryPaging(ended), .end)

        // The server RESTARTS a list on a stale cursor and answers 200 with
        // page one. The store loads cache-first, so an archive cached days ago
        // makes this the ordinary path rather than a corner.
        var restarted = seasonSection([season("a", year: 2026)], cursor: "c1")
        restarted.appendOlder([season("a", year: 2026)], cursor: "c1")
        XCTAssertEqual(ParcelHistoryPaging(restarted), .noneShown)

        // The distinction is in the words, not only in the enum.
        XCTAssertEqual(ParcelHistoryCopy.noOlder, "Няма по-стари записи.")
        XCTAssertEqual(ParcelHistoryCopy.noneShown, "Няма повече записи за показване.")
        XCTAssertNotEqual(ParcelHistoryCopy.noOlder, ParcelHistoryCopy.noneShown)
    }

    /// The blank footer row: `footer` returns an `EmptyView` for `.nothing`,
    /// the ORDINARY case for a section that arrived whole — and it was still
    /// added as a List row inside a padded, full-width VStack. Every complete
    /// section ended with a contentless row, its separator, and a VoiceOver
    /// stop with nothing to read.
    ///
    /// Asserted on the condition the view now guards with, since the row's
    /// absence is not observable from here.
    func testACompleteSectionDrawsNoFooterRowAtAll() {
        let whole = seasonSection([season("a", year: 2026)], cursor: nil)
        XCTAssertEqual(ParcelHistoryPaging(whole), .nothing)
        XCTAssertNil(whole.failure)

        var failed = seasonSection([season("a", year: 2026)], cursor: nil)
        failed.failure = "Няма връзка."
        XCTAssertEqual(ParcelHistoryPaging(failed), .nothing)
        XCTAssertNotNil(failed.failure, "a failure still earns a footer")
    }

    /// A failed page must not take the rows with it. Every row on screen is
    /// still good, and replacing them with an error view would throw away
    /// pages the reader waited for in order to report that the NEXT one did
    /// not arrive.
    ///
    /// The control also stays a button, so the retry is the same tap it was.
    func testAFailureLeavesTheRowsAndTheRetryInPlace() {
        let failed = seasonSection(
            [season("a", year: 2026), season("b", year: 2025)],
            cursor: "c1", failure: "Няма връзка със сървъра.")

        XCTAssertEqual(failed.items.count, 2)
        XCTAssertEqual(failed.failure, "Няма връзка със сървъра.")
        XCTAssertEqual(ParcelHistoryPaging(failed), .button)
        XCTAssertEqual(card(failed).newest?.text, "2026 · Пшеница")
    }
    // MARK: - What the rows were dropping

    /// `targetNote` is the agronomic REASON a spray happened — production's
    /// own example is «балур на петна» — and it is what somebody opening
    /// "what was applied here" came to read. It was decoded by the model and
    /// rendered by nothing.
    func testTheReasonForASprayReachesTheRow() async throws {
        let line = try await decode(#"""
        {"id":"op9","taskId":"t","operationType":"SPRAY","title":"Хербицид",
         "completedAt":null,"productName":"Раундъп","doseValue":"2.5",
         "doseUnit":"л/дка","targetNote":"балур на петна"}
        """#, as: ParcelHistoryOperation.self).historyLine

        // `text` is the first line (« 3 май · Хербицид »); the reason lands
        // on the second, with the product and the dose.
        XCTAssertTrue(line.detailText.contains("балур на петна"), line.detailText)
        XCTAssertTrue(line.detailText.contains("Раундъп"), line.detailText)
        XCTAssertTrue(line.spoken.contains("балур на петна"), line.spoken)
    }

    /// The РЕКОЛТИ drill-in carried nothing the card did not: a reader who
    /// tapped a card with three seasons learned only that there were three.
    /// Sowing and harvest dates and the farmer's own note were all decoded
    /// and rendered nowhere.
    ///
    /// Each date is prefixed because the pair is the point — two bare dates
    /// side by side are indistinguishable, and «сято … / прибрано …» is the
    /// shape of an autumn crop.
    func testTheSeasonDrillInCarriesMoreThanItsCard() async throws {
        let season = try await decode(#"""
        {"id":"cs9","year":2026,"cropType":"Wheat",
         "sownAt":"2025-10-14T11:00:00.000Z","harvestedAt":"2026-07-02T11:00:00.000Z",
         "notes":"късна сеитба"}
        """#, as: CropSeason.self)

        let card = season.historyLine
        let detail = season.historyDetailLine

        // Both share the first line — « 2026 · Пшеница ». The drill-in adds a
        // second one the card does not have at all.
        XCTAssertEqual(card.text, detail.text)
        XCTAssertTrue(card.detailText.isEmpty, card.detailText)
        XCTAssertTrue(detail.detailText.contains("сято"), detail.detailText)
        XCTAssertTrue(detail.detailText.contains("прибрано"), detail.detailText)
        XCTAssertTrue(detail.detailText.contains("късна сеитба"), detail.detailText)
    }

    /// `isBlank` could not fire when it was written: `doseValue` was
    /// non-optional, so `details` always held a dose. That made it a guard
    /// that cannot fire — the defect this repo has shipped three times.
    ///
    /// Making `doseValue` optional turned it live, so it now gets the test it
    /// never had: a line with no date, no recorded title, no recorded product
    /// and no dose has nothing to say, and declares no label rather than an
    /// empty one.
    func testAnOperationWithNothingRecordedDeclaresNoLabel() async throws {
        let line = try await decode(#"""
        {"id":"op0","taskId":"t","operationType":null,"title":"",
         "completedAt":null,"productName":"","doseValue":null,
         "doseUnit":"","targetNote":null}
        """#, as: ParcelHistoryOperation.self).historyLine

        XCTAssertTrue(line.isBlank)
        XCTAssertEqual(line.text, "")
        XCTAssertEqual(line.detailText, "")
        XCTAssertEqual(line.spoken, "")
    }

}
