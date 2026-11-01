import UIKit
import XCTest

/// Screenshots of REAL screens at whatever accessibility settings the device
/// is carrying — the thing issue #97 was written on the assumption nobody
/// could do here.
///
/// ── The assumption, and where it is wrong ──
///
/// #97 says the simulator "cannot be driven from this machine (no assistive
/// access, no `simctl` input verb)". Both halves of that are true and neither
/// one covers XCUITest. A UI test does not synthesise touches through
/// assistive access; the test runner is a second process that talks to the
/// app over the accessibility server, which is how `tap()` reaches a tab bar
/// button with Switch Control and Voice Control both switched off. `simctl`
/// having no `input` verb says nothing about it.
///
/// What #97 IS right about is that nothing here can check a GESTURE. This
/// file taps where a finger would land and photographs the result; it cannot
/// tell you whether a drag across Борса announces each oblast, whether Switch
/// Control can reorder the bottom bar, or whether the recogniser answers to
/// «Изпрати». Those need the phone. Which of #97's 20 items this touches and
/// which it cannot is written out in a comment on that issue — `gh issue view
/// 97 --comments` — rather than in a document that lives outside the repo.
///
/// ── What it photographs: FIXTURES, not the farm (agrent-ios#115) ──
///
/// The app is launched with `AGRENT_UITEST_FIXTURES`, the DEBUG-only seam in
/// `Agrent/Debug/UITestSeam.swift`. Under it the app skips `SignInView`,
/// hands `APIClient` stub tokens that never leave the process, and
/// `FixtureURLProtocol` answers every GET from `Tests/Fixtures` and every
/// write with `501 WRITE_REFUSED` — before URLSession opens a socket.
///
/// Until #115 this suite had no seam. It launched bare, relied on the
/// simulator's Keychain already holding the owner's token, and every capture
/// was a live read of the production tenant. That had two costs, and the
/// second is why it changed:
///
///   1. It needed a simulator somebody had signed in on, so it could not run
///      anywhere else — a precondition this file used to fail loudly on.
///   2. It could not photograph MESSAGING at all. Opening a conversation
///      POSTs a mark-read that another farm sees, and a stray tap on
///      «Съобщение до продавача» opens a thread in another farm's inbox. A
///      read-only suite against production had to stay out of those screens.
///
/// The trade the owner accepted: the screenshots are now renders of
/// SYNTHETIC payloads of the right shape. They evidence layout, contrast and
/// Dynamic Type; they are no longer evidence of what the live tenant holds.
/// The #97 coverage comment says which checklist items that changes.
///
/// ── Read-only, STILL, even though nothing could land ──
///
/// Every write is refused by the seam, so a mistaken tap here would reach
/// nothing. The suite still taps no save, send, close, block, retract,
/// «Изпрати» or «Съобщение до …», and nothing should be added that does: a
/// suite whose safety is ONE mechanism is a suite that becomes unsafe the day
/// somebody runs it with that mechanism off. `assertSeamActive` is the check
/// that it is on.
///
/// Output still goes outside the repository (`scripts/a11y-shots.sh`), now
/// for tidiness rather than secrecy: the captures carry only fixture data,
/// plus Apple's satellite imagery of the fixture's made-up coordinates.
@MainActor
final class A11yShotsTests: XCTestCase {

    /// `UITestSeam.launchArgument`, COPIED — the one place it is.
    ///
    /// A UI test bundle runs in its own process and cannot link the app, so
    /// it cannot read the constant. If the two ever disagree the app opens on
    /// `SignInView`, and `assertSeamActive` fails naming this property.
    private static let seamArgument = "AGRENT_UITEST_FIXTURES"
    /// `UITestSeam.offlineArgument`, copied for the same reason.
    private static let offlineArgument = "AGRENT_UITEST_OFFLINE"
    /// `UITestSeam.operatorArgument`, copied for the same reason: the
    /// fixture person is a MECHANISATOR (#465).
    private static let operatorArgument = "AGRENT_UITEST_OPERATOR"

    /// A failed step leaves the app on an unknown screen, and the screenshots
    /// taken after it would be of that screen under the previous one's name.
    override func setUp() {
        continueAfterFailure = false
    }

    /// One test, not three. Each `xcodebuild test` invocation is a fresh
    /// install and launch — 29 to 41 seconds across the eight runs measured on
    /// 2026-09-26 — and the matrix in `scripts/a11y-shots.sh` already pays that
    /// once per SETTING. Three test methods would pay it per screen as well.
    func testCaptureTheScreensThatCarryTheChecklist() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        // TABLO'S BLOCKS, PINNED — in the argument domain, which is volatile.
        //
        // `DashboardPreferences` reads `dashboard.blocks` from UserDefaults,
        // and the simulator keeps whatever somebody last chose in the picker.
        // The first seam run photographed «Последни записи» and «Моите задачи»
        // only — no briefing, no price chart, no task-trend chart — so the
        // chart-legend and Bulgarian-axis items #97 settles from this capture
        // were not on it. `-key value` puts the four default blocks in
        // NSArgumentDomain for THIS process only: nothing is written to the
        // app's defaults, and the next manual launch sees the owner's choice.
        // Spelled as `DashboardBlock.defaultOrder`'s raw values, copied for
        // the same can-not-link reason as `seamArgument`.
        app.launchArguments += ["-dashboard.blocks", "(briefing, grainPrice, journal, taskTrend)"]
        app.launch()

        assertSeamActive(app)

        // ── ONE capture, when a change needs only its own screen ──
        //
        // `ONLY=<name> scripts/a11y-shots.sh` arrives here as `A11Y_ONLY` —
        // the `TEST_RUNNER_` channel the old `ROW=` knob used. The seam and
        // the fixture world are still asserted first: a targeted run is no
        // less able to be pointed at production than a full one. Unknown
        // names FAIL rather than fall through to the full walk, so a typo
        // cannot quietly cost a run of every screen.
        if let only = Self.only {
            assertFixtureWorld(app)
            switch only {
            case "08-tasks": captureTabOrMenu("08-tasks", label: "Задачи", app: app)
            case "09-overhead-costs": captureOverheadCosts(app)
            case "09a-crop-costs": captureCropCosts(app)
            case "01b-farm-record": captureFarmRecordSheet(app)
            case "01c-journal-filter": captureJournalFilter(app)
            case "01e-journal-treatment", "01g-treatment-correction", "01i-treatment-trail",
                 "01j-treatment-correction-areas":
                captureJournalTreatment(app)
            case "17-new-entry", "17b-new-activity": captureNewEntryForm(app)
            case "01k-activity-correction", "01l-activity-correction-check", "01m-activity-correction-parcels",
                 "01n-journal-harvest":
                captureActivityCorrection(app)
            case "19-admin-prices": captureAdminPrices(app)
            case "19c-public-profile": capturePublicProfile(app)
            case "04-parcel-map-orthophoto":
                openTheLocation(app)
                XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 20),
                              "the location did not push a screen")
                captureOrthophotoMap(app)
            case "18-operation-typed-product":
                openTheLocation(app)
                captureOperationSheet(app)
            case "08b-task-parcel-lines": captureFieldOperationTask(app)
            case "08d-task-parcels": captureTaskParcels(app)
            case "06-news": captureNews(app)
            case "16-profile": captureProfile(app)
            case "17-farm-wizard": captureFarmWizard(app)
            case "09d-farm-search":
                openTheExchange(app)
                captureFarmSearch(app)
            case "13-listing-message-party":
                openTheExchange(app)
                captureListingWithMessageParty(app)
            default: XCTFail("A11Y_ONLY=\(only) names no capture this suite can run alone")
            }
            return
        }

        // Дневник, the launch screen. #97 asks whether a list row stacks at
        // AX sizes and whether the `·` between the values disappears with it;
        // this row is `JournalRow` → `AdaptiveRow` → `MetaRow`, the exact
        // shape PR #93 changed.
        capture("01-journal", app: app)
        assertFixtureWorld(app)
        captureFarmRecordSheet(app)
        captureJournalFilter(app)
        captureJournalTreatment(app)
        captureActivityCorrection(app)
        captureNewEntryForm(app)

        // ── The screens reached from the menu, done BEFORE Локации ──
        //
        // Локации pushes into a location and then cycles the map mode, so it
        // ends two screens deep with `@AppStorage` state to restore. Doing the
        // menu screens first means every one of them starts from the same
        // place — the Дневник root — and a failure in one cannot leave the next
        // somewhere unexpected.
        //
        // Риск, Новини and Табло are NOT tabs by default: the bottom bar comes
        // from /api/auth/me and holds five of nine surfaces, so these live in
        // `tabs.overflow` and open as sheets from the menu. Админ is an
        // unconditional menu row. That means the menu is the only read-only
        // route to them — moving a surface into the bar goes through
        // `BottomTabsStore.save()`, which is a PUT against the live tenant.
        captureFromMenu("05-risk", label: "Риск", app: app)
        captureNews(app)
        captureFromMenu("07-dashboard", label: "Табло", app: app)
        captureAdmin(app)
        captureProfile(app)
        captureFarmWizard(app)

        // Задачи and Борса ARE in the default bar — but the bar is whatever the
        // server sent, so this asks the tab bar first and falls back to the
        // menu rather than assuming. A suite that assumes a tab exists reports
        // "no Задачи button" for a farm that simply arranged its bar
        // differently.
        captureTabOrMenu("08-tasks", label: "Задачи", app: app)
        captureCropCosts(app)
        captureOverheadCosts(app)
        captureFieldOperationTask(app)
        captureTaskParcels(app)

        // Борса, and from it the messaging screens #114 built and #115 made
        // photographable. Its own method because it goes four screens deep.
        captureExchangeAndMessaging(app)

        // Локации → a location's map: the one #97 calls "the one that matters
        // most", because Increase Contrast is what switches the near-solid
        // fill on and the label outline is the answer to it.
        XCTAssertTrue(app.tabBars.buttons["Блокове"].waitForExistence(timeout: 10),
                      "no «Блокове» button in the tab bar")
        app.tabBars.buttons["Блокове"].tap()

        // A fixture answers in milliseconds, so this wait is for the push and
        // the first layout rather than a network. Kept at 20s anyway: it
        // costs nothing on a pass, and a first launch on a cold simulator is
        // slower than anyone expects.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20),
                      "Локации showed no rows within 20s — locations-list.json did not load")
        capture("02-locations", app: app)

        // THE ONE LOCATION. `locations-list.json` holds exactly one —
        // «Synthetic Land», three parcels: one with four holes, one plain, one
        // with no geometry. There used to be a `ROW=` knob here to pick the
        // owner's real farm over a sample field on the live tenant; in the
        // fixture world there is nothing to pick between, so it is gone.
        app.cells.firstMatch.tap()

        // There is no element to wait on inside either map — the satellite
        // modes are one MapKit view (the orthophoto replaced the Canvas), and both
        // are one opaque rectangle. The navigation bar's back button is the
        // closest thing to a signal that the push completed. The parcels come
        // from a fixture, but the SATELLITE tiles are still Apple's, fetched by
        // MapKit outside the seam (see `FixtureURLProtocol`'s header).
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 20),
                      "the location did not push a screen")
        // A fixed wait, and it is a guess rather than a measurement: nothing
        // published by the map says "the tiles are drawn". If a capture
        // comes out blank this is the number to raise.
        Thread.sleep(forTimeInterval: 6)
        capture("03-parcel-map-precise", app: app)

        captureOrthophotoMap(app)
        captureOperationSheet(app)
    }

    /// Локации → the fixture world's one location, for a capture run alone
    /// (`ONLY=18-operation-typed-product`); the full walk is already there.
    private func openTheLocation(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["Блокове"].waitForExistence(timeout: 10),
                      "no «Блокове» button in the tab bar")
        app.tabBars.buttons["Блокове"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20),
                      "Локации showed no rows within 20s — locations-list.json did not load")
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 20),
                      "the location did not push a screen")
    }

    // MARK: - The spray sheet's typed product (agrent-ios#237)

    /// A parcel row's operation sheet with a NEW product typed: the farm's own
    /// products offered under the field, and the «Нов продукт» section the
    /// server needs for a name it will create. Opened, typed into,
    /// photographed and cancelled — «Запиши» would be a write, and the first
    /// real one is the owner's (the seam would answer it 501 regardless).
    ///
    /// «синтетичен» is part of both of `items.json`'s own products and the
    /// whole of neither, so one capture holds the suggestions AND the
    /// registration fields. Starts on a location's map.
    private func captureOperationSheet(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTH-1")).firstMatch
        // Dragged from near the bottom, on the list: a swipe from the middle
        // would land on the map and pan it instead of scrolling the page.
        for _ in 0..<4 where !(row.exists && row.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "no parcel row for SYNTH-1 — may the fixture person not record operations?")
        row.tap()

        // A row opens the parcel's history since #387 (owner, 2026-10-21),
        // and «Ново мероприятие» is there.
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10),
                      "the parcel row opened no history")
        // Its risk, at the top (owner, 2026-10-29): the reading Риск shows.
        let risk = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Риск, зеленина")).firstMatch
        XCTAssertTrue(risk.waitForExistence(timeout: 10), "the parcel from Блокове shows no «Риск»\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("18a-parcel-history-from-map", app: app)

        // Its tasks (#462, owner 2026-10-29): the card under «Риск», then
        // «Текущи» and «Архив», then back for «Ново мероприятие».
        let tasksCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Задачи, 2 текущи")).firstMatch
        XCTAssertTrue(tasksCard.waitForExistence(timeout: 10),
                      "the parcel from Блокове shows no «Задачи» card\n\(app.debugDescription)")
        tasksCard.tap()
        XCTAssertTrue(app.navigationBars["Задачи"].waitForExistence(timeout: 10), "the «Задачи» card opened no list")
        let current = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Пръскане срещу плевели")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), "«Текущи» shows no current task")
        Thread.sleep(forTimeInterval: 1)
        capture("18c-parcel-tasks", app: app)

        // «Изтрий» here too (owner, 2026-10-30), as on Задачи: the question,
        // then «Отмени» inside the window, so no delete is ever built.
        let deletable = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Заявка за анализ на почвата'")).firstMatch
        XCTAssertTrue(deletable.waitForExistence(timeout: 10), "no deletable task on «Текущи»")
        deletable.swipeLeft()
        let delete = app.buttons["Изтрий"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the parcel's task offered no «Изтрий»\n\(app.debugDescription)")
        delete.tap()
        let question = app.alerts["Сигурни ли сте, че искате да изтриете задачата?"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "«Изтрий» asked nothing")
        question.buttons["Изтрий"].tap()
        let undo = app.buttons["Отмени"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no «Отмени» after «Изтрий»")
        XCTAssertFalse(deletable.exists, "the task stayed in the parcel's list")
        capture("18f-parcel-task-undo", app: app)
        undo.tap()
        XCTAssertTrue(deletable.waitForExistence(timeout: 5), "«Отмени» did not bring the task back")

        app.buttons["Архив"].tap()
        let archived = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Дискуване след жътва")).firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 10), "«Архив» shows no finished task")
        Thread.sleep(forTimeInterval: 1)
        capture("18d-parcel-tasks-archive", app: app)
        app.navigationBars["Задачи"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10), "no way back to the parcel")

        // Its comments (#465): a comment and a closing note, newest first.
        let commentsCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Коментари, 2 коментара")).firstMatch
        XCTAssertTrue(commentsCard.waitForExistence(timeout: 10),
                      "the parcel shows no «Коментари» card\n\(app.debugDescription)")
        commentsCard.tap()
        XCTAssertTrue(app.navigationBars["Коментари"].waitForExistence(timeout: 10), "the card opened no list")
        let note = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "При затваряне на задачата")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the closing note is not listed")
        Thread.sleep(forTimeInterval: 1)
        capture("18e-parcel-comments", app: app)
        app.navigationBars["Коментари"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10), "no way back to the parcel")
        let record = app.buttons["Ново мероприятие"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the history has no «Ново мероприятие»")
        record.tap()

        let name = app.textFields["Търговско наименование"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "«Ново мероприятие» opened no operation sheet")
        name.tap()
        // The newline submits, which puts the keyboard away so the section
        // under the field is in the picture.
        name.typeText("синтетичен\n")
        XCTAssertTrue(app.buttons["Почвен подобрител, синтетичен запис"].waitForExistence(timeout: 10),
                      "the typed text offered none of the farm's own products")
        Thread.sleep(forTimeInterval: 1)
        capture("18-operation-typed-product", app: app)

        // The «Нов продукт» section, under the suggestions — below the fold
        // at the accessibility sizes, where a Form builds no row it has not
        // shown, so it is scrolled to rather than waited for.
        let registration = app.staticTexts["Нов продукт"]
        for _ in 0..<5 where !registration.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(registration.waitForExistence(timeout: 5), "a new name asked for no registration")
        Thread.sleep(forTimeInterval: 1)
        capture("18b-operation-new-product", app: app)

        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet has no «Отказ»")
        cancel.tap()
        // Back from the history to the map, where the next capture starts.
        let history = app.navigationBars["История"]
        if history.waitForExistence(timeout: 5) { history.buttons.element(boundBy: 0).tap() }
    }

    /// «Ортофотокарта» (#458), which replaced the schematic and is up to two
    /// taps away.
    ///
    /// `ParcelMapView` defaults to `.precise` and the toolbar button CYCLES
    /// precise → simplified → orthophoto → precise (`ParcelMapMode.next`).
    /// The button's accessibility label is the mode it takes you TO, so the
    /// mode the screen is IN is read off the label rather than counted in
    /// taps: the button offers «Точни очертания» exactly when the orthophoto
    /// is on screen. `mode` is `@AppStorage`, so it survives the run, and a
    /// count from an assumed start once failed the fourth variant of
    /// `scripts/a11y-shots.sh` on state the third left behind.
    ///
    /// The seam has no tiles, so this photographs what the map draws with no
    /// photo: the plain ground, the parcels' outlines and names, the
    /// fixture's physical blocks and numbers, and the footer.
    ///
    /// THE LAST TAP IS THE CLEANUP, for the same `@AppStorage` reason.
    private func captureOrthophotoMap(_ app: XCUIApplication) {
        for _ in 0..<mapModeDestinations.count {
            if app.navigationBars.buttons[orthophotoIsOn].exists { break }
            guard let next = mapModeDestinations
                .map({ app.navigationBars.buttons[$0] })
                .first(where: { $0.exists })
            else {
                XCTFail("""
                No map-mode button in the toolbar. Expected one labelled with the mode \
                it switches TO — «Опростена», «Ортофотокарта» or «Точни очертания», from \
                ParcelMapMode.label.
                """)
                return
            }
            next.tap()
            // The cycle also moves the camera (`ParcelMapView.cycleMode`), and
            // a tap sent into the middle of that animation is dropped rather
            // than queued.
            Thread.sleep(forTimeInterval: 1)
        }

        guard app.navigationBars.buttons[orthophotoIsOn].exists else {
            XCTFail("cycled through every map mode without reaching the orthophoto")
            return
        }
        let footer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Ортофото: МЗХ"))
            .firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 10), "the orthophoto has no footer\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 3)
        capture("04-parcel-map-orthophoto", app: app)

        app.navigationBars.buttons[orthophotoIsOn].tap()
    }

    /// The three labels `ParcelMapMode.label` can put on the toolbar button.
    /// Spelled out here rather than imported: a UI test target runs in its own
    /// process and cannot link the app, so these strings are a copy and will
    /// go stale if the labels change. The `XCTFail` above says so by name.
    private let mapModeDestinations = ["Опростена", "Ортофотокарта", "Точни очертания"]

    /// The button offers «Точни очертания» exactly when the orthophoto is
    /// what is on screen.
    private var orthophotoIsOn: String { "Точни очертания" }


    // MARK: - «Дневник (PDF)» (agrent-ios#246)

    /// The Дневник page's «Дневник (PDF)»: the location (`locations-list.json`
    /// holds one, so it is chosen and named) and the period. Opened,
    /// photographed and cancelled — «Изтегли» is a POST the seam answers 501,
    /// and the document itself is the server's to build. Starts on Дневник.
    private func captureFarmRecordSheet(_ app: XCUIApplication) {
        let open = app.navigationBars.buttons["Дневник (PDF)"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Дневник has no «Дневник (PDF)»")
        open.tap()
        // The campaign picker (#436), the current campaign chosen: no block
        // and no dates since the farm's diary replaced the per-block one.
        let campaign = app.buttons["Кампания"]
        XCTAssertTrue(campaign.waitForExistence(timeout: 10), "the sheet offers no «Кампания»")
        Thread.sleep(forTimeInterval: 1)
        capture("01b-farm-record", app: app)
        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet has no «Отказ»")
        cancel.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10), "«Отказ» did not put Дневник back")
    }

    // MARK: - Админ → «Цени» (agrent-ios#258)

    /// The superuser's day of prices, on the fixture's platform farm
    /// (`me-farms.json`'s first row carries `isPlatform`). Opened and
    /// photographed only: nothing is typed and «Запази» is never tapped,
    /// because a price saved here changes every farm's figures, and a suite
    /// that relies on the seam to catch a write is one typo from production.
    /// Starts on any tab; ends with Админ closed.
    private func captureAdminPrices(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Админ")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        let prices = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Цени")).firstMatch
        // At AX5 the account card fills the first screen and a lazy list has
        // not built the rows below it yet.
        if !prices.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(prices.waitForExistence(timeout: 10),
                      "Админ offered no «Цени» — me-farms.json's platform flag did not reach the gate")
        prices.tap()
        XCTAssertTrue(app.navigationBars["Цени"].waitForExistence(timeout: 10), "«Цени» did not push its page")
        Thread.sleep(forTimeInterval: 2)
        capture("19-admin-prices", app: app)
        // «Торове и гориво», below the fold: the long names are here —
        // «Нафта (дизелово гориво), €/л» takes two lines beside its field at
        // the default size, and the row must grow by the second one.
        let diesel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Нафта")).firstMatch
        // The last row of a lazy list, eleven rows down: a handful of swipes
        // at the default size, and many at AX5, where a row fills the screen.
        for _ in 0..<30 where !(diesel.exists && diesel.isHittable) { app.swipeUp() }
        XCTAssertTrue(diesel.exists, "«Цени» has no «Нафта» row — admin-price-overrides.json lost its inputs")
        Thread.sleep(forTimeInterval: 1)
        capture("19b-admin-prices-inputs", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let close = app.navigationBars.buttons["Затвори"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "«Цени» did not go back to Админ")
        close.tap()
    }

    // MARK: - «Публичен профил» (agrent-ios#323)

    /// Админ → «Публичен профил» on `farm-brand.json`, a published page: the
    /// facts first, then «Публикуване» with «Сподели», «Карта за печат (A6)»
    /// and «Спри публикуването». Taps none of the three: the card is a GET
    /// with no fixture, and withdrawing is a write.
    private func capturePublicProfile(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Админ")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Публичен профил")).firstMatch
        // Below the account card, which fills the first screen at AX5.
        for _ in 0..<8 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "Админ offered no «Публичен профил» — auth-me.json's flag did not reach the gate")
        row.tap()
        XCTAssertTrue(app.navigationBars["Публичен профил"].waitForExistence(timeout: 10),
                      "«Публичен профил» did not push its page")
        Thread.sleep(forTimeInterval: 2)
        capture("19c-public-profile", app: app)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Карта за печат")).firstMatch
        for _ in 0..<30 where !(card.exists && card.isHittable) { app.swipeUp() }
        XCTAssertTrue(card.exists, "no «Карта за печат» — farm-brand.json is not a published page")
        Thread.sleep(forTimeInterval: 1)
        capture("19d-public-profile-publication", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let close = app.navigationBars.buttons["Затвори"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "«Публичен профил» did not go back to Админ")
        close.tap()
    }

    // MARK: - The Дневник's filter (agrent-ios#252)

    /// Дневник → «Филтри»: the sheet, with «Synthetic Land» as the one block
    /// and the fixture parcels' crops. Then «Тип» is set to «Дейност» and
    /// shown, so the summary row above the entries is photographed too, and
    /// the filter is cleared. Reads only. The fixture answers a filtered page
    /// with `journal-list.json` (paths match without their query), so the
    /// rows are the same and the summary is what this captures. Starts and
    /// ends on Дневник.
    private func captureJournalFilter(_ app: XCUIApplication) {
        let open = app.navigationBars.buttons["Филтри"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Дневник has no «Филтри»")
        open.tap()
        // `MenuPicker` names its menu by its title, so a loaded block list is
        // a «Блок» button; while it loads, «Блок» is a row with a spinner.
        let block = app.buttons["Блок"]
        XCTAssertTrue(block.waitForExistence(timeout: 15),
                      "the sheet offered no blocks — locations-list.json did not load")
        XCTAssertTrue(app.buttons["Култура"].waitForExistence(timeout: 15),
                      "the sheet offered no crops — locations-parcels.json did not load")
        Thread.sleep(forTimeInterval: 1)
        capture("01c-journal-filter", app: app)

        // The menu's own button, inside the row `MenuPicker` names. At AX5
        // the title stacks above it, and a tap at the row's centre landed on
        // the title, two points above the menu, so it opened nothing. XCUITest
        // calls the inner button not hittable, because the row is the
        // accessibility element, so it is tapped by its coordinate.
        let typeRow = app.buttons["Тип"]
        let typeMenu = typeRow.buttons.firstMatch
        (typeMenu.exists ? typeMenu : typeRow)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The first type, so it is on screen without scrolling the menu at AX5.
        let activity = app.buttons["Дейност"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5), "«Тип» did not offer «Дейност»")
        activity.tap()
        app.navigationBars.buttons["Покажи"].tap()

        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Филтри, Тип: Дейност"))
            .firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "the filtered list has no summary row")
        Thread.sleep(forTimeInterval: 1)
        capture("01d-journal-filtered", app: app)

        let clear = app.buttons["Изчисти филтрите"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "the summary row has no «Изчисти филтрите»")
        clear.tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 15), "«Изчисти филтрите» left the filter on")
    }

    // MARK: - A treatment's own screen (agrent-ios#320)

    /// Дневник → `journal-list.json`'s folded treatment: what was done, and
    /// «Изтегли PDF» — which is NOT tapped, as no fixture answers a PDF.
    /// The row and the back button are the only taps.
    private func captureJournalTreatment(_ app: XCUIApplication) {
        // By its product: a folded treatment is titled by it, and the row
        // speaks one sentence that starts with its title.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Тестов хербицид"))
            .firstMatch
        // UP first: `assertFixtureWorld` left the list at its foot, and the
        // treatment is its second row, which a lazy List may not have built.
        var swipes = 0
        while !row.waitForExistence(timeout: swipes == 0 ? 10 : 3), swipes < 6 {
            if swipes < 4 { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(row.exists, "Дневник has no treatment row — journal-list.json's second row")
        row.tap()

        // The dose is the signal the row's treatment decoded into the screen.
        let dose = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "литра на декар"))
            .firstMatch
        XCTAssertTrue(dose.waitForExistence(timeout: 10), "the entry opened without its treatment")
        Thread.sleep(forTimeInterval: 1)
        capture("01e-journal-treatment", app: app)

        let pdf = app.buttons["Изтегли PDF"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 5), "the treatment offers no «Изтегли PDF»")
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            XCTAssertTrue(scrollWhollyIntoView(pdf, in: app), "the page would not scroll «Изтегли PDF» into view")
            Thread.sleep(forTimeInterval: 1)
            capture("01f-journal-treatment-pdf", app: app)
        }
        captureTreatmentTrail(app)
        captureTreatmentCorrection(app)
        goBack(app, to: "Земеделски дневник")
    }

    /// The same entry's «Корекции» (agri-saas #2292): `treatment-corrections.json`'s
    /// one correction, who and when, and what the pest and the period were.
    private func captureTreatmentTrail(_ app: XCUIApplication) {
        let corrected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Коригирано на"))
            .firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 10), "the entry shows no «Корекции»")
        XCTAssertTrue(corrected.label.contains("Вредител: беше Плевели"), corrected.label)
        XCTAssertTrue(scrollWhollyIntoView(corrected, in: app), "the page would not scroll «Корекции» into view")
        Thread.sleep(forTimeInterval: 1)
        capture("01i-treatment-trail", app: app)
    }

    /// The same treatment's «Коригирай» (#392): the form prefilled from
    /// `treatment-definition.json`, every recorded field correctable
    /// (agri-saas #2293); then a growth stage typed and «Проверка» with that
    /// one change. Left
    /// by «Отказ»: «Запази» is a write to a farm's register, and the seam
    /// would refuse it anyway.
    private func captureTreatmentCorrection(_ app: XCUIApplication) {
        let correct = app.buttons["Коригирай"]
        XCTAssertTrue(correct.waitForExistence(timeout: 5), "the treatment offers no «Коригирай»")
        // Below the tab bar at every size: `isHittable` says yes there, and
        // the tap lands on the bar.
        XCTAssertTrue(scrollWhollyIntoView(correct, in: app), "the page would not scroll «Коригирай» into view")
        correct.tap()

        // The product section's own line, near the top: the parcel rows
        // further down may not be built yet.
        let locked = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "С корекция се избира продукт"))
            .firstMatch
        guard locked.waitForExistence(timeout: 10) else {
            XCTFail("«Коригирай» opened without its definition:\n\(app.debugDescription)")
            return
        }
        Thread.sleep(forTimeInterval: 1)
        capture("01g-treatment-correction", app: app)

        // By its title or its prompt: with a prompt given, the field can be
        // exposed under the prompt, as «Количество» is under «0».
        let stage = app.textFields
            .matching(NSPredicate(format: "label == %@ OR placeholderValue BEGINSWITH %@",
                                  "Фенофаза/BBCH", "напр. BBCH"))
            .firstMatch
        var swipes = 0
        while !stage.exists, swipes < 6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            swipes += 1
        }
        XCTAssertTrue(stage.exists, "no «Фенофаза/BBCH» field")
        XCTAssertTrue(scrollWhollyIntoView(stage, in: app), "the form would not scroll the stage into view")
        stage.tap()
        stage.typeText("BBCH 31")
        let next = app.buttons["Напред"]
        XCTAssertTrue(next.isEnabled, "one change, and «Напред» still dimmed")
        next.tap()

        let change = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Фенофаза/BBCH: беше няма, става BBCH 31"))
            .firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5), "«Проверка» doesn't read the change back")
        Thread.sleep(forTimeInterval: 1)
        capture("01h-treatment-correction-check", app: app)

        // Back to the form, to its foot: the block's parcels ticked, its third
        // offered (agri-saas #2304), then each ticked one's treated area.
        app.buttons["BackButton"].firstMatch.tap()
        // The stage field kept its keyboard; a return closes it, as a
        // single-line field's does, so the areas aren't under it.
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            app.typeText("\n")
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The block's third parcel, offered and not ticked, is the list's
        // last row; under it, the areas.
        let area = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTH-3"))
            .firstMatch
        var down = 0
        while !area.exists, down < 6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            down += 1
        }
        XCTAssertTrue(area.exists, "the block's other parcel isn't offered")
        XCTAssertTrue(scrollWhollyIntoView(area, in: app), "the form would not scroll the areas into view")
        Thread.sleep(forTimeInterval: 1)
        capture("01j-treatment-correction-areas", app: app)

        app.buttons["Отказ"].firstMatch.tap()
        XCTAssertTrue(correct.waitForExistence(timeout: 5), "«Отказ» didn't close the correction")
    }

    /// «Коригирай» on a harvest (#439, agri-saas #2375): `journal-list.json`'s
    /// last row, the form prefilled from `activity-definition.json` with its
    /// day and total; then a new total and «Проверка» with that one change.
    /// Left by «Отказ»: «Запази» is a write. Starts and ends on Дневник.
    private func captureActivityCorrection(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Прибиране на реколтата"))
            .firstMatch
        // The list's last row: down until a lazy List has built it.
        var swipes = 0
        while !row.waitForExistence(timeout: swipes == 0 ? 5 : 2), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists, "Дневник has no harvest row — journal-list.json's last row")
        XCTAssertTrue(scrollWhollyIntoView(row, in: app), "the list would not scroll the harvest into view")
        row.tap()

        let correct = app.buttons["Коригирай"]
        XCTAssertTrue(correct.waitForExistence(timeout: 10), "the harvest offers no «Коригирай»")
        XCTAssertFalse(app.buttons["Изтегли PDF"].exists, "a harvest has no ДНЕВНИК page")
        // Its one total, from the row (#446, agri-saas #2389).
        let shownTotal = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "килограма"))
            .firstMatch
        XCTAssertTrue(shownTotal.waitForExistence(timeout: 5), "the harvest's entry doesn't show its total")
        Thread.sleep(forTimeInterval: 1)
        capture("01n-journal-harvest", app: app)
        XCTAssertTrue(scrollWhollyIntoView(correct, in: app), "the page would not scroll «Коригирай» into view")
        correct.tap()

        // By its title or its prompt, as on a treatment's correction.
        let total = app.textFields
            .matching(NSPredicate(format: "label == %@ OR placeholderValue == %@ OR value == %@",
                                  "Количество", "кг", "4200"))
            .firstMatch
        guard total.waitForExistence(timeout: 10) else {
            XCTFail("«Коригирай» opened without the harvest's definition:\n\(app.debugDescription)")
            return
        }
        Thread.sleep(forTimeInterval: 1)
        capture("01k-activity-correction", app: app)

        // Its parcels (#447): the block's, the recorded two ticked and its
        // third offered, then «Добави парцели от друг блок».
        let other = app.buttons["Добави парцели от друг блок"]
        var down = 0
        while !other.exists, down < 6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            down += 1
        }
        if other.exists {
            XCTAssertTrue(scrollWhollyIntoView(other, in: app), "the form would not scroll «Друг блок» into view")
            Thread.sleep(forTimeInterval: 1)
            capture("01m-activity-correction-parcels", app: app)
        } else {
            // One block on the fixture farm: nothing else to add, and the
            // parcels are the form's foot.
            let third = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTH-3")).firstMatch
            XCTAssertTrue(third.exists, "the block's other parcel isn't offered")
            Thread.sleep(forTimeInterval: 1)
            capture("01m-activity-correction-parcels", app: app)
        }
        // Back up to the total, for the change «Проверка» reads back.
        var up = 0
        while !total.isHittable, up < 6 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.5)
            up += 1
        }

        // At the field's trailing edge, where the right-aligned «4200» ends,
        // so the cursor is after it: emptied, then the new total.
        total.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        total.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "4300")
        let next = app.buttons["Напред"]
        XCTAssertTrue(next.isEnabled, "one change, and «Напред» still dimmed")
        next.tap()

        let change = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Прибрано: беше 4"))
            .firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5), "«Проверка» doesn't read the change back")
        Thread.sleep(forTimeInterval: 1)
        capture("01l-activity-correction-check", app: app)

        app.buttons["Отказ"].firstMatch.tap()
        XCTAssertTrue(correct.waitForExistence(timeout: 5), "«Отказ» didn't close the correction")
        goBack(app, to: "Земеделски дневник")
    }

    // MARK: - «Култура» (agrent-ios#245)

    /// Калкулатор → «Нов разход», which opens on «Култура»: the calculator
    /// fixture's wheat, prefilled from `costs-defaults-crop.json` — rent
    /// converted from leva, two named plant-protection rows, and a fertiliser
    /// last entered as a total. Opened, photographed and cancelled — «Запази»
    /// would be a write. Starts on any tab; ends on Дневник.
    private func captureCropCosts(_ app: XCUIApplication) {
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        tab.tap()
        let add = app.buttons["Нов разход"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the calculator has no «Нов разход»")
        add.tap()
        // The crop picker, valued with the fixture's first crop: at the top,
        // where AX5 still has it; the sections under it are below the fold.
        let crop = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Култура", "Пшеница"))
        XCTAssertTrue(crop.firstMatch.waitForExistence(timeout: 10), "«Култура» drew no crop picker on «Пшеница»")
        Thread.sleep(forTimeInterval: 2)
        capture("09a-crop-costs", app: app)
        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet has no «Отказ»")
        cancel.tap()
        app.tabBars.buttons["Дневник"].tap()
    }

    // MARK: - «Общи» (agrent-ios#245)

    /// Калкулатор → «Нов разход» → «Общи»: the year's overheads, prefilled
    /// from `costs-defaults.json` (3 people × 12 000, and «Друго») and the
    /// machine register's figure from `costs-machinery.json`, with its
    /// «сумата е занижена» caveat. Opened, photographed and cancelled —
    /// «Запази» would be a write. Starts on any tab; ends on Дневник.
    private func captureOverheadCosts(_ app: XCUIApplication) {
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        tab.tap()
        let add = app.buttons["Нов разход"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the calculator has no «Нов разход»")
        add.tap()
        let overheads = app.buttons["Общи"]
        XCTAssertTrue(overheads.waitForExistence(timeout: 10), "«Нов разход» has no «Общи»")
        overheads.tap()
        XCTAssertTrue(app.staticTexts["Заплати"].waitForExistence(timeout: 10), "«Общи» drew no «Заплати»")
        Thread.sleep(forTimeInterval: 2)
        capture("09-overhead-costs", app: app)
        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet has no «Отказ»")
        cancel.tap()
        app.tabBars.buttons["Дневник"].tap()
    }

    // MARK: - reaching the screens that are not tabs

    /// «ИЗХОД» IS TWO TAPS FROM THE MENU, so nothing here may tap by index.
    ///
    /// `AppMenuButton` lists the overflow surfaces, then Админ in a section
    /// of its own. Since 2026-10-07 «Профил» and «Изход» are no longer menu
    /// rows: Админ's top row pushes Профил, whose destructive «Изход» asks
    /// once and then calls
    /// `auth.signOut()` — which clears the Keychain. The question is a second
    /// tap, not a guard to lean on. Under the seam `AuthClient.signOut` does less (see the note
    /// on `AgrentApp.openingState`), but the simulator this runs on may well
    /// be the owner's, holding a real Google session in that Keychain, and a
    /// guard that relies on the seam being on is a guard that fails exactly
    /// when the seam is not.
    ///
    /// Every lookup below is by label. There is no `element(boundBy:)`
    /// anywhere in this file's menu handling, and there must not be.
    private func openMenu(_ app: XCUIApplication) -> Bool {
        let menu = app.buttons["Меню"]
        guard menu.waitForExistence(timeout: 10) else { return false }
        menu.tap()
        return true
    }

    /// Tap a menu row by its exact label, refusing «Изход» explicitly.
    ///
    /// The refusal is belt and braces — no caller passes it — but a guard that
    /// only exists in a comment is the failure mode this project keeps finding,
    /// so it is code.
    private func tapMenuRow(_ label: String, in app: XCUIApplication) -> Bool {
        guard label != "Изход" else {
            XCTFail("this suite must never tap «Изход» — it would clear the Keychain")
            return false
        }
        let row = labelled(label, in: app.buttons)
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap()
        return true
    }

    /// The button whose label IS `label`, or is `label` followed by a
    /// counted suffix — «Борса (2)».
    ///
    /// `MessagingPolicy.counted` appends « (N)» to Борса's menu row and to
    /// the «Съобщения» segment whenever a thread is unread, and
    /// `exchange-threads.json` has two unread on purpose. An exact match would
    /// find nothing; a bare BEGINSWITH would let «Борса» match a hypothetical
    /// «Борсата …» row. So: exact, or exact plus « (».
    ///
    /// Still never «Изход»: nothing starts with a label that could be it.
    private func labelled(_ label: String, in query: XCUIElementQuery) -> XCUIElement {
        query.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", label, "\(label) ("
        )).firstMatch
    }

    /// Open a menu-presented screen, photograph it, and put it back.
    private func captureFromMenu(_ name: String, label: String, app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for \(label)")
        XCTAssertTrue(tapMenuRow(label, in: app),
                      "«\(label)» is not in the menu — it may be in the bottom bar")

        // These sheets all load over the network. There is no single element
        // common to six different screens worth waiting on, so this waits for
        // the sheet's own navigation bar and then gives the content a fixed
        // moment. A guess, and named as one: if a capture comes out empty this
        // is the number to raise.
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                      "«\(label)» did not present a sheet")
        Thread.sleep(forTimeInterval: 4)
        capture(name, app: app)
        dismissSheet(app, named: label)
    }

    /// Новини with the fixture person's topics (agrent-ios#231): the feed on
    /// «Моите теми», then «Предпочитания» over it. The switches are only
    /// looked at — a flip is a PUT, and the first real one is the owner's.
    private func captureNews(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Новини")
        XCTAssertTrue(tapMenuRow("Новини", in: app), "«Новини» is not in the menu — it may be in the bottom bar")
        // The scope chips appear only once the topics are read, so they are
        // the signal that the catalogue and the choices both arrived.
        let mine = app.buttons["Моите теми"]
        XCTAssertTrue(mine.waitForExistence(timeout: 20), "Новини opened without the person's topics")
        Thread.sleep(forTimeInterval: 2)
        capture("06-news", app: app)

        let preferences = app.navigationBars.buttons["Предпочитания"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5), "Новини has no «Предпочитания»")
        preferences.tap()
        XCTAssertTrue(app.switches["Пшеница"].waitForExistence(timeout: 10),
                      "«Предпочитания» opened without the catalogue's topics")
        Thread.sleep(forTimeInterval: 1)
        capture("06b-news-preferences", app: app)
        let done = app.navigationBars.buttons["Готово"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "«Предпочитания» has no «Готово»")
        done.tap()
        XCTAssertTrue(preferences.waitForExistence(timeout: 10), "«Готово» did not put Новини back")
        dismissSheet(app, named: "Новини")
    }

    /// A surface that is normally a tab, but need not be.
    private func captureTabOrMenu(_ name: String, label: String, app: XCUIApplication) {
        let tab = labelled(label, in: app.tabBars.buttons)
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                          "the «\(label)» tab showed nothing")
            Thread.sleep(forTimeInterval: 4)
            capture(name, app: app)
            // Back to the launch tab so the next step starts where it expects.
            app.tabBars.buttons["Дневник"].tap()
            return
        }
        captureFromMenu(name, label: label, app: app)
    }

    /// `A11Y_ONLY`, or nil — empty counts as unset, since the script passes
    /// the variable through whether or not `ONLY` was given.
    private static var only: String? {
        let value = ProcessInfo.processInfo.environment["A11Y_ONLY"] ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: - A field operation's parcel lines (agrent-ios#138)

    /// The field-operation task from `tasks-list.json`, with its three lines
    /// in their three states: «Чакащо» with «Готово» and «Пропусни»,
    /// «Готово» and «Пропуснато» each with «Отвори отново».
    ///
    /// ── NOTHING ON THE SCREEN IS TAPPED ──
    ///
    /// A real mark deducts stock and files a ДНЕВНИК row, and the first one
    /// is the owner's. Under the seam a mark is a 501 that never leaves the
    /// process; the suite does not rely on that, as the header says. The row
    /// that opens the task and the back button are the only taps.
    private func captureFieldOperationTask(_ app: XCUIApplication) {
        let tab = labelled("Задачи", in: app.tabBars.buttons)
        let isTab = tab.waitForExistence(timeout: 3)
        if isTab {
            tab.tap()
        } else {
            XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Задачи")
            XCTAssertTrue(tapMenuRow("Задачи", in: app), "«Задачи» is neither a tab nor a menu row")
        }
        // By its title: the row speaks one sentence that starts with it.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Пръскане срещу плевели"))
            .firstMatch
        // At the accessibility sizes the third row starts below the fold, and
        // a List builds rows lazily — it does not exist until scrolled to.
        // Vertical swipes on a list can only scroll; bounded, so a row that
        // is really missing still fails here rather than swiping forever.
        var swipes = 0
        while !row.waitForExistence(timeout: swipes == 0 ? 20 : 3), swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists, "Задачи has no field-operation row — tasks-list.json's third row")
        row.tap()

        // The progress line is the signal that field-operation-detail.json
        // decoded: two of three finished, a skip counting as progress.
        XCTAssertTrue(app.staticTexts["2 / 3 парцела завършени"].waitForExistence(timeout: 20),
                      "the task opened without its parcel lines")
        Thread.sleep(forTimeInterval: 2)
        capture("08b-task-parcel-lines", app: app)

        // ── The task map at the accessibility sizes (agrent-ios#177) ──
        //
        // Found by its spoken summary, which also proves the fixture's two
        // outlined parcels made it onto the map. Below the fold at these
        // sizes, so the page is scrolled until the whole map shows — see
        // `scrollWhollyIntoView`.
        let map = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Карта на парцелите. Чакащо: SYNTH-1. Готово: SYNTH-2."))
            .firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), "the field operation has no task map")
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            XCTAssertTrue(scrollWhollyIntoView(map, in: app), "the page would not scroll the task map into view")
            Thread.sleep(forTimeInterval: 2)
            capture("08c-task-map", app: app)
        }

        goBack(app, to: "Задачи")
        if isTab {
            app.tabBars.buttons["Дневник"].tap()
        } else {
            dismissSheet(app, named: "Задачи")
        }
    }

    /// A task that is NOT a field operation, with its parcels (agrent-ios#177):
    /// `tasks-list.json`'s row 1, «Заявка за анализ на почвата», whose
    /// `task-parcels.json` holds two outlined parcels and one without. The
    /// row that opens the task and the back button are the only taps.
    private func captureTaskParcels(_ app: XCUIApplication) {
        let tab = labelled("Задачи", in: app.tabBars.buttons)
        let isTab = tab.waitForExistence(timeout: 3)
        if isTab {
            tab.tap()
        } else {
            XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Задачи")
            XCTAssertTrue(tapMenuRow("Задачи", in: app), "«Задачи» is neither a tab nor a menu row")
        }
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Заявка за анализ на почвата"))
            .firstMatch
        // UP first: the field operation's capture may have left the list
        // scrolled to its third row, and a List builds rows lazily, so the
        // first row may not exist until the list is back at its top.
        var swipes = 0
        while !row.waitForExistence(timeout: swipes == 0 ? 20 : 3), swipes < 6 {
            if swipes < 2 { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(row.exists, "Задачи has no plain-task row — tasks-list.json's row 1")
        row.tap()

        // The map's spoken summary is the signal that task-parcels.json
        // decoded and both outlines made it onto the map.
        let map = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@",
                                  "Карта на парцелите. Парцели на задачата: SYNTH-1, SYNTH-2."))
            .firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20), "the task opened without its parcels map")
        XCTAssertTrue(scrollWhollyIntoView(map, in: app), "the page would not scroll the parcels map into view")
        Thread.sleep(forTimeInterval: 2)
        capture("08d-task-parcels", app: app)

        // ── The comments at the foot of the same task (agrent-ios#225) ──
        //
        // Found by the composer, the section's last element, so the capture
        // holds the comments above it. Nothing is typed and nothing is sent:
        // a comment is a write to the task, and the first one is the owner's.
        // A vertical field may surface as a text view, so both types match.
        let composer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
                                  "Коментар",
                                  XCUIElement.ElementType.textField.rawValue,
                                  XCUIElement.ElementType.textView.rawValue))
            .firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "the task has no comment composer")
        XCTAssertTrue(scrollWhollyIntoView(composer, in: app), "the page would not scroll the comments into view")
        Thread.sleep(forTimeInterval: 1)
        capture("08e-task-comments", app: app)

        // ── The green tick's form (agrent-ios#226) ──
        //
        // Opened and photographed, then «Отказ»: «Завърши» would complete
        // the task, which is a write — the first real one is the owner's. The
        // fixture person is the farm's OWNER, so the tick is there.
        let tick = app.navigationBars.buttons["Завърши задачата"]
        XCTAssertTrue(tick.waitForExistence(timeout: 10), "the task has no green tick")
        tick.tap()
        XCTAssertTrue(app.staticTexts["Задачата изпълнена ли е успешно?"].waitForExistence(timeout: 10),
                      "the tick opened no form")
        Thread.sleep(forTimeInterval: 1)
        capture("08f-task-close", app: app)
        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the form has no «Отказ»")
        cancel.tap()
        XCTAssertTrue(tick.waitForExistence(timeout: 10), "«Отказ» did not put the task back")

        goBack(app, to: "Задачи")
        if isTab {
            app.tabBars.buttons["Дневник"].tap()
        } else {
            dismissSheet(app, named: "Задачи")
        }
    }

    /// Scrolls the page until `element`'s WHOLE frame clears the tab bar (or
    /// the window's foot when there is none) — `isHittable` is already true
    /// for an element whose top edge shows. True when it got there.
    ///
    /// Short drags, started on the element while it is well up the screen:
    /// a task map takes no gestures (`interactionModes: []`), so a finger on
    /// it must still scroll the page. If it ever swallows the drag, the map
    /// never rises and the caller's assertion says so — which is a bug a
    /// farmer would meet.
    private func scrollWhollyIntoView(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let floor = app.tabBars.firstMatch.exists
            ? app.tabBars.firstMatch.frame.minY
            : app.windows.firstMatch.frame.maxY
        // FAR below first — the foot of a long page at the accessibility
        // sizes, where a task's comments are (#225): whole swipes until it is
        // on the screen at all, then the short drags place it. A swipe moves
        // less than the screen is tall, so one that starts with the element
        // below the floor cannot carry it past the top.
        var swipes = 0
        while element.frame.minY > floor, swipes < 12 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            swipes += 1
        }
        var drags = 0
        while element.frame.maxY > floor, drags < 8 {
            let from = element.frame.minY < floor - 40
                ? element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -220)))
            Thread.sleep(forTimeInterval: 0.5)
            drags += 1
        }
        return element.frame.maxY <= floor
    }

    // MARK: - Борса and messaging (agrent-ios#115)

    /// Борса, a listing that is not ours, the inbox, and one conversation.
    ///
    /// ── Why this could not exist before the seam ──
    ///
    /// Opening a conversation fires `POST /exchange/threads/{id}/read`, which
    /// the other farm's members see as their message having been read. Against
    /// production that is a write from a suite that promises none. Under the
    /// seam it is answered `501 WRITE_REFUSED` inside the process and
    /// `ConversationStore` swallows it, as it must for a real outage.
    ///
    /// ── What is NOT tapped, and must never be ──
    ///
    /// «Съобщение до продавача» (POSTs open-thread), «Изпрати» on the listing
    /// (opens the inquiry composer, whose own «Изпрати» POSTs), the composer's
    /// send, and «Действия» (close, block, unblock). Each is photographed
    /// where it is visible and left alone. The seam would refuse all of them;
    /// the suite does not rely on that.
    ///
    /// ── Which rows, and why by label ──
    ///
    /// The listing is `exchange-listings.json` row 1, the synthetic SUNFLOWER
    /// one, because row 0 is `isOwn` and an own listing offers no «Съобщение
    /// до …» at all. The conversation is `thr_synthetic_1`, the only thread
    /// `FixtureCatalogue` serves, found by its seller name — the only inbox row
    /// that has one. Tapping row 2 or 3 would open a `NO_FIXTURE` screen.
    private func captureExchangeAndMessaging(_ app: XCUIApplication) {
        // A tab by default (the bar comes from `auth-me.json`'s null
        // `bottomTabOrder`, i.e. the default five), a menu row otherwise.
        // Either way it may read «Борса (2)».
        let tab = labelled("Борса", in: app.tabBars.buttons)
        let isTab = tab.waitForExistence(timeout: 3)
        if isTab {
            tab.tap()
        } else {
            XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Борса")
            XCTAssertTrue(tapMenuRow("Борса", in: app), "«Борса» is neither a tab nor a menu row")
        }
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                      "Борса showed nothing")
        Thread.sleep(forTimeInterval: 3)
        capture("09-exchange", app: app)
        captureExchangeMap(app)
        captureMyListings(app)
        captureFarmSearch(app)

        captureListingWithMessageParty(app)
        captureInboxAndConversation(app)

        // Back to the launch tab WITHOUT popping the conversation. The way
        // back is a navigation bar that also holds «Действия», and the one
        // safe tap there is the one that is not needed: switching tabs leaves
        // Борса's stack where it is and nothing below revisits it.
        //
        // As a menu SHEET it is different: switching tabs is impossible under
        // a sheet, and #120's «Затвори» sits on the sheet's ROOT only. So pop
        // once — `goBack` finds the back button by label and cannot land on
        // «Действия» — and then close from the root.
        if isTab {
            app.tabBars.buttons["Дневник"].tap()
        } else {
            goBack(app, to: "Борса")
            dismissSheet(app, named: "Борса")
        }
    }

    /// Борса as a tab, for a capture run alone; the full walk opens it in
    /// `captureExchangeAndMessaging`, tab or menu.
    private func openTheExchange(_ app: XCUIApplication) {
        let tab = labelled("Борса", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Борса» in the tab bar")
        tab.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20), "Борса showed nothing")
    }

    /// Борса's one search finds farms (2026-10-24; `farm-directory.json`):
    /// «Синтетично» typed and searched, and the «Ферми» section above the
    /// listings shows the farm — its name, tagline, oblast and crops, the
    /// long row wrapping at AX sizes. A GET only. No farm is tapped: its page
    /// is the real web's, loaded outside the seam. The search is cleared
    /// after, so the board is back as it was.
    private func captureFarmSearch(_ app: XCUIApplication) {
        // The search is «Обяви»'s; the step before this one leaves «Моите
        // обяви» open.
        let browse = labelled("Обяви", in: app.buttons)
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        // By its label: a vertical-axis TextField reaches the tree as a text
        // VIEW, with the search-field trait, not as a text field.
        // Two can match — an off-screen copy has an infinite frame — so the
        // one on screen.
        let fields = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType != %d", "Търсене",
                                  XCUIElement.ElementType.image.rawValue))
        _ = fields.firstMatch.waitForExistence(timeout: 5)
        guard let field = fields.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("no search field on Борса")
            return
        }
        field.tap()
        field.typeText("Синтетично\n")
        // A row is one element whose label is its spoken sentence, which
        // starts with the farm's name.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Синтетично стопанство"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 10),
                      "the search showed no farms — is social.public-profile on in auth-me.json?")
        capture("09d-farm-search", app: app)
        let clear = app.buttons["Изчисти търсенето"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        if field.exists {
            field.tap()
            field.typeText("\n")
        }
    }

    /// «Моите обяви» (`exchange-my-listings.json`), the seller's own rows:
    /// the crop beside its status, which a plain `HStack` would break
    /// mid-word at AX5 as it broke the board's crop beside «ваша». A GET
    /// only. Put back on «Обяви» at once — the steps after this find the
    /// board's rows.
    private func captureMyListings(_ app: XCUIApplication) {
        let mine = app.buttons["Моите обяви"]
        guard mine.waitForExistence(timeout: 5) else {
            XCTFail("no «Моите обяви» on Борса")
            return
        }
        mine.tap()
        Thread.sleep(forTimeInterval: 2)
        capture("09c-exchange-mine", app: app)
        let browse = app.buttons["Обяви"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "no «Обяви» to put Борса back")
        browse.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// Борса's map (`ExchangeMapView`), for its oblast fills (#156). The
    /// toggle is `@AppStorage("exchange.showMap")`, which outlives the run,
    /// so it is flipped back at once: the steps after this find listing ROWS,
    /// and the owner's next launch should open on the list it opened on.
    private func captureExchangeMap(_ app: XCUIApplication) {
        let toMap = app.buttons["Покажи карта"]
        guard toMap.waitForExistence(timeout: 5) else {
            XCTFail("no «Покажи карта» on Борса")
            return
        }
        toMap.tap()
        Thread.sleep(forTimeInterval: 2)
        capture("09b-exchange-map", app: app)
        let toList = app.buttons["Покажи списък"]
        XCTAssertTrue(toList.waitForExistence(timeout: 5), "no «Покажи списък» to put Борса back")
        toList.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// «Нов запис», the most-used of the app's `Form`s (#156) — since #293
    /// step one of the treatment record — opened and CANCELLED. «Напред»
    /// stays untouched, and nothing is saved before step three's «Добави»
    /// anyway.
    private func captureNewEntryForm(_ app: XCUIApplication) {
        let open = app.buttons["Нов запис"]
        guard open.waitForExistence(timeout: 5) else {
            XCTFail("no «Нов запис» on Дневник")
            return
        }
        open.tap()
        let cancel = app.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "«Нов запис» did not present its form")
        // Two seconds, not one: the product field waits on items.json and the
        // dose on units-rate.json. Not awaited by name, because at AX5 they
        // are below the fold and a lazy form has not built its rows yet.
        Thread.sleep(forTimeInterval: 2)
        capture("17-new-entry", app: app)
        captureNewActivity(app)
        cancel.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10),
                      "«Отказ» did not close «Нов запис»")
    }

    /// The same form with «Резитба» chosen (#439): no product, dose or period,
    /// then the one crop's parcels and «Проверка». Left from «Проверка» by
    /// «Отказ»: «Добави» writes a farm's register, and the seam refuses it.
    /// Ends on the form's «Отказ», which the caller taps.
    private func captureNewActivity(_ app: XCUIApplication) {
        let kind = app.buttons["Вид"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "no «Вид» on «Нов запис»")
        kind.tap()
        let prune = app.buttons["Резитба"]
        XCTAssertTrue(prune.waitForExistence(timeout: 5), "no «Резитба» in «Вид»")
        prune.tap()
        XCTAssertFalse(app.textFields["Търговско наименование"].exists, "a product field on other work")
        Thread.sleep(forTimeInterval: 1)
        capture("17b-new-activity", app: app)

        let next = app.buttons["Напред"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no «Напред»")
        XCTAssertTrue(next.isEnabled, "«Напред» dimmed on a pruning with its day")
        next.tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Избери всички'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 15), "no parcels on «Къде»")
        all.tap()
        let proceed = app.buttons["Продължи"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5), "no «Продължи»")
        proceed.tap()
        let add = app.buttons["Добави"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no «Проверка» for the pruning")
        Thread.sleep(forTimeInterval: 1)
        capture("17c-new-activity-check", app: app)
        // Back to the form by the way back, not «Отказ», which would close
        // the sheet under the caller.
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Вид"].waitForExistence(timeout: 5), "not back on the form")

        // «Сеитба» (agri-saas #2368): the seed and its rate, none of a
        // spraying's own fields.
        app.buttons["Вид"].tap()
        let sow = app.buttons["Сеитба"]
        XCTAssertTrue(sow.waitForExistence(timeout: 5), "no «Сеитба» in «Вид»")
        sow.tap()
        XCTAssertTrue(app.textFields["Сорт"].waitForExistence(timeout: 5), "no «Сорт» field on a sowing")
        XCTAssertFalse(app.staticTexts["Вредител"].exists, "a pest on a sowing")
        Thread.sleep(forTimeInterval: 1)
        capture("17d-new-sowing", app: app)
    }

    /// The listing detail with «Съобщение до продавача» on it — photographed,
    /// never tapped.
    private func captureListingWithMessageParty(_ app: XCUIApplication) {
        // The row's combined label is `A11y.sentence([crop, side, region])`, so
        // it BEGINS with the crop. `.any` because a SwiftUI List row is not
        // reliably a `.cell` with its label — see the Админ note below, where
        // assuming so photographed the wrong row.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Слънчоглед"))
            .firstMatch
        guard reveal(row, in: app, what: "the synthetic «Слънчоглед» listing") else { return }
        row.tap()

        let messageParty = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Съобщение до"))
            .firstMatch
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10),
                      "the listing did not push a screen")
        if reveal(messageParty, in: app, what: "«Съобщение до продавача»") {
            capture("13-listing-message-party", app: app)
        }
        goBack(app, to: "Борса")
    }

    /// «Съобщения» on Борса's bar (2026-10-24; a section until then) → the
    /// inbox → `thr_synthetic_1`.
    private func captureInboxAndConversation(_ app: XCUIApplication) {
        // The count is the button's VALUE, so its label is «Съобщения».
        let section = labelled("Съобщения", in: app.buttons)
        XCTAssertTrue(section.waitForExistence(timeout: 10),
                      "no «Съобщения» on Борса's bar")
        section.tap()

        let thread = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Синтетично стопанство"))
            .firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10),
                      "the inbox did not show thr_synthetic_1 — exchange-threads.json did not load")
        Thread.sleep(forTimeInterval: 1)
        capture("14-messages-inbox", app: app)

        guard reveal(thread, in: app, what: "the thr_synthetic_1 inbox row") else { return }
        thread.tap()

        // The tombstone is the one message whose label is known in advance
        // and unique to the conversation, so its arrival means the page
        // decoded — not merely that a screen was pushed.
        let tombstone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Съобщението е премахнато"))
            .firstMatch
        XCTAssertTrue(tombstone.waitForExistence(timeout: 10),
                      "the conversation did not render exchange-thread.json")
        // Long enough for the mark-read POST to be refused and swallowed, so
        // the capture is of the settled screen rather than of one mid-write.
        Thread.sleep(forTimeInterval: 2)
        capture("15-conversation", app: app)
    }

    /// Scroll until `element` is on screen, or say why not.
    ///
    /// At AX5 a list row can be several screens down and SwiftUI's `List` does
    /// not create a row that far below the fold, so "does not exist" can mean
    /// "not scrolled to yet". Six swipes — three was measured too few for the
    /// listing detail's last section at AX5 — then a verdict: at an
    /// ACCESSIBILITY size a miss is printed and the capture skipped — the
    /// lesson the Админ swipe taught, where one unreachable row cost a whole
    /// variant its screenshots — and at any other size it is a failure,
    /// because there the screen fits and a miss is a real regression.
    ///
    /// A swipe is safe here in a way it was not on Админ: nothing on these
    /// screens has a swipe action.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, what: String) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        if element.exists && element.isHittable { return true }
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            print("SKIPPED \(what): not reachable at this text size after six swipes.")
        } else {
            XCTFail("\(what) is not on screen at a non-accessibility text size")
        }
        return false
    }

    /// Pop one screen by the back button, found by the title it returns to.
    ///
    /// NOT `navigationBars.buttons.firstMatch`: the conversation's bar also
    /// holds «Действия», and on this screen the only thing a mis-tap could
    /// open is a menu of writes. «Back» is the fallback the system uses when
    /// the title does not fit.
    private func goBack(_ app: XCUIApplication, to title: String) {
        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@",
                                  title, "Back", "Назад"))
            .firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button to «\(title)»")
        back.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// «Затвори» when there is one, a drag when there is not.
    ///
    /// Since #120 every surface the menu presents gets «Затвори» from the
    /// presentation site (`closeWhenPresentedFromMenu`), Табло included — it
    /// used to have none, which is why this fallback exists. The drag stays
    /// for the case #120 does not cover: a screen PUSHED inside a menu sheet
    /// (a conversation inside a Борса sheet) has a back button, not «Затвори».
    ///
    /// Tries the button first and falls back to the drag, rather than choosing
    /// per screen: one path that works for both is less to keep true than a
    /// list of which screens have a button.
    private func dismissSheet(_ app: XCUIApplication, named label: String) {
        let close = app.buttons["Затвори"]
        if close.exists {
            close.tap()
        } else {
            // From just under the sheet's top edge to well down the screen. A
            // `swipeDown()` on the app window starts too low and scrolls the
            // sheet's own content instead of moving the sheet.
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            top.press(forDuration: 0.1, thenDragTo: bottom)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10),
                      "«\(label)» would not close — the run cannot continue from here")
    }

    /// Админ's three rows, the farm profile MASKED (page and editor), the
    /// members page, and the swipe that #99 is about.
    ///
    /// ── Since 2026-10-01 these are three screens, not one ──
    ///
    /// Админ is an index now: «Стопанство», «Долна лента», «Потребители» —
    /// under the account card, which this asserts before the capture and does
    /// not tap here: it opens Профил, and `captureProfile` goes through it —
    /// the one route to that page since 2026-10-07.
    /// The profile and the members each push their own page, so this walks
    /// into each and back rather than photographing one long list.
    ///
    /// ── The ЕГН is never revealed ──
    ///
    /// The farm profile carries a national identity number behind «Покажи».
    /// `FarmProfileView` and its editor draw dots until that is tapped, so
    /// simply never tapping it means no identity number is written to a PNG —
    /// the row's layout, contrast and Dynamic Type are all still visible, which
    /// is what the audit changed. The owner chose this over skipping the
    /// screen or revealing it. (On the seam the number is a synthetic run of
    /// zeros anyway; the rule is kept because it is the rule.)
    ///
    /// ── The editor is OPENED and never SAVED ──
    ///
    /// «Запази» is a PUT of the whole profile. On the seam it would get 501,
    /// but a suite that taps a write button and relies on the seam to catch
    /// it is one launch-argument typo from writing to production. Nothing
    /// here is typed into the form either, so «Отказ» closes it without the
    /// unsaved-changes question.
    ///
    /// There is no assertion that the digits are absent, and that is honest
    /// rather than lazy: the guarantee is that nothing taps «Покажи», which is
    /// a property of this code, not of the image.
    ///
    /// ── The swipe ──
    ///
    /// agrent-ios#99. On the last active owner the deactivate action is absent,
    /// so the row springs back with nothing revealed and no explanation. A
    /// probe could not settle what `.swipeActions` renders for a non-Button —
    /// its positive control came back empty, so it proved nothing — and a real
    /// swipe photographed is the only answer available here.
    private func captureAdmin(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Админ")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                      "Админ did not present a sheet")
        Thread.sleep(forTimeInterval: 4)

        // ── The account card, above «Стопанство» (2026-10-04) ──
        //
        // ONE element whose label is the whole sentence — asserted by its
        // exact text, so a card that split back into three VoiceOver stops
        // (picture, name, address) fails here rather than in a person's ear.
        // The fixture account is `auth-me.json`'s; its picture request has no
        // fixture on purpose, so the capture below shows the INITIALS circle.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@",
                                  "Вписан като Иван Фикстуров, owner@example.invalid"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no account card on Админ")
        capture("10-admin", app: app)

        // ── «Стопанство» at the accessibility sizes (#150) ──
        //
        // At AX5 the card fills the first screen and the farm row's value —
        // the producer's name, which must WRAP rather than end «Синтети…» —
        // starts below the fold. One swipe brings it up; the list has no
        // swipe actions on these rows, so a swipe can only scroll.
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            capture("10b-admin-farm-row", app: app)
        }

        // ── «Стопанство», the first row ──
        //
        // A NavigationLink's label is the row's combined text — «Стопанство,
        // Синтетично стопанство ЕООД» on the fixture — so BEGINSWITH, not ==.
        let farmRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Стопанство"))
            .firstMatch
        XCTAssertTrue(farmRow.waitForExistence(timeout: 10), "no «Стопанство» row on Админ")
        farmRow.tap()
        XCTAssertTrue(app.navigationBars["Профил на стопанството"].waitForExistence(timeout: 10),
                      "«Стопанство» did not push the farm profile")
        Thread.sleep(forTimeInterval: 1)

        // No assertion that the digits are absent. `x && false` would have
        // been one that cannot fail, which is the defect this repo has spent a
        // week removing — and there is nothing honest to assert here anyway:
        // the guarantee is that this method never taps «Покажи», which is a
        // property of the code above and not of the image below.
        capture("13-admin-farm-profile-masked", app: app)

        // The editor, opened and photographed, then left by «Отказ». The
        // button is asserted rather than optional: the seam serves a profile
        // the server "sent", so an admin must be offered the edit — its
        // absence would be the regression.
        let edit = app.navigationBars.buttons["Редактирай"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5),
                      "no «Редактирай» over a profile the server sent")
        edit.tap()
        let cancel = app.navigationBars.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the editor did not open")
        Thread.sleep(forTimeInterval: 1)
        capture("14-admin-farm-profile-edit", app: app)
        // NOT «Запази». See the doc comment: this suite never taps a write.
        cancel.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10),
                      "«Отказ» on an untouched editor did not close it — the "
                      + "unsaved-changes guard is firing without changes")
        goBack(app, to: "Админ")

        // ── «Потребители», the last row ──
        let membersRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Потребители"))
            .firstMatch
        // SCROLLED TO, since the account card went on top (2026-10-04). At
        // AX5 the card stacks — circle, name, a character-wrapped email — and
        // takes most of a screen, so «Потребители» is below the fold and a
        // lazy List has not built its cell: `waitForExistence` alone failed
        // there and only there. Vertical swipes on the list, never on a row
        // (a horizontal swipe on a row is what opens its actions), bounded so
        // a row that is really gone still fails below rather than looping.
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !membersRow.waitForExistence(timeout: 2) {
            list.swipeUp()
        }
        XCTAssertTrue(membersRow.waitForExistence(timeout: 10), "no «Потребители» row on Админ")
        membersRow.tap()
        XCTAssertTrue(app.navigationBars["Потребители"].waitForExistence(timeout: 10),
                      "«Потребители» did not push the members page")
        Thread.sleep(forTimeInterval: 1)
        capture("15-admin-members", app: app)

        // THE SWIPE, AND WHY IT IS SAFE ONLY SINCE `allowsFullSwipe: false`.
        //
        // Until that landed, `.swipeActions(edge: .trailing)` had full swipe
        // ENABLED and the first action was `Button(role: .destructive)` calling
        // `store.setActive(member, active: false)`. `XCUIElement.swipeLeft()`
        // is a fast gesture that completes a full swipe, so photographing the
        // revealed actions would have DEACTIVATED A REAL MEMBER of the owner's
        // farm — a write, against production, from a suite whose whole premise
        // is that it only reads.
        //
        // Full swipe is off now, so the actions reveal and nothing fires until
        // a button is tapped. Nothing here taps one.
        //
        // Worth keeping as the general rule: a read-only suite is only
        // read-only if every GESTURE is read-only. A tap can be checked by
        // reading which button it lands on; a swipe can trigger an action
        // nobody named at the call site.
        // THE OWNER'S ROW, BY LABEL — not `cells.firstMatch`.
        //
        // The first cell on this screen USED TO BE «Долна лента» under
        // «Приложение», which has no swipe actions at all — the members shared
        // Админ with it until 2026-10-01. Swiping it photographed an untouched
        // screen and looked like a successful capture; only opening the image
        // showed the swipe had answered a different question. The members page
        // has no other rows now, and matching by label still holds.
        //
        // The row carries a combined label built by `A11y.sentence`, which
        // includes the role — so «Собственик» finds the owner, who is also the
        // LAST ACTIVE OWNER and therefore exactly the case #99 is about.
        // `.other`, NOT `.cells`. Measured: on this screen all 18 cells have
        // an EMPTY label, and the combined row label — «Eivo Ivanov,
        // Собственик, 11 активни сесии.», built by `A11y.sentence` — sits on
        // an `.other` element inside the cell. So `cells.matching(label ...)`
        // matches nothing, and `cells.firstMatch` is «Долна лента», which has
        // no swipe actions at all.
        //
        // That first attempt photographed an untouched screen and passed. The
        // capture is what showed it had answered a different question.
        // AT AX5 THE MEMBER ROWS ARE BELOW THE FOLD, and this used to cost the
        // whole variant.
        //
        // «Долна лента» alone filled most of an accessibility5 screen when it
        // shared the list, so the first member row started off-screen. On
        // its own page the «Поканен» section still comes first. The swipe checks then failed the
        // test, `continueAfterFailure` is false, and the run produced ZERO
        // screenshots for the one text size the Dynamic Type items are about.
        // A check that cannot run taking the captures down with it is the worst
        // of both.
        //
        // So: scroll toward them first, and if they are still not reachable,
        // skip the swipe pair and say so. The #99 assertions run at the other
        // three sizes, and what AX5 is FOR is the layout capture above.
        //
        // ONLY IF NEEDED. The unconditional swipe this used to be was tuned
        // to the live tenant, whose member rows started lower. On the fixture
        // (`admin-members.json`, four rows under an «Поканен» section) the
        // owner is mid-screen at the default size, and a blind swipe scrolled
        // it up under the navigation bar — unhittable, so the #99 pair was
        // skipped at the one size where it must run. Measured on the first
        // seam run, 2026-09-30.
        let ownerRow = app.descendants(matching: .other)
            .matching(NSPredicate(format: "label CONTAINS %@", "Собственик"))
            .firstMatch
        if !(ownerRow.waitForExistence(timeout: 5) && ownerRow.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        guard ownerRow.waitForExistence(timeout: 10), ownerRow.isHittable else {
            // NOT silent. The variant's output is short two files and this says
            // why, so a reader comparing directories is not left guessing.
            print("SKIPPED the #99 swipe checks: no hittable «Собственик» row at this "
                  + "text size. Expected at the accessibility sizes; if it happens at "
                  + "the default size, access is refused or the row label changed.")
            goBack(app, to: "Админ")
            dismissSheet(app, named: "Админ")
            return
        }
        ownerRow.swipeLeft()
        Thread.sleep(forTimeInterval: 1)
        // #99's answer is in this image: whether SwiftUI renders a non-Button
        // in a swipe slot at all. If the slot is empty, the `Label` in
        // `AdminView.actions(for:)` has to become a disabled Button.
        // ASSERTED, not just photographed. #99's answer is that a bare `Label`
        // in a swipe slot renders nothing and a disabled Button does — so if
        // somebody changes `AdminView.actions(for:)` back to a non-Button, the
        // explanation silently disappears again and only this fails.
        XCTAssertTrue(app.buttons["Последният собственик не може да се деактивира"].exists,
                      "the last owner's row revealed no explanation — a non-Button in a "
                      + "swipeActions slot renders nothing, see AdminView.actions(for:)")
        capture("11-admin-row-swiped", app: app)
        ownerRow.swipeRight()
        Thread.sleep(forTimeInterval: 1)

        // THE POSITIVE CONTROL, which is the whole reason this pair exists.
        //
        // An «Администратор» is not the last owner, so its slot holds a real
        // `Button(role: .destructive)`. If THIS swipe reveals «Деактивирай»
        // and the owner's does not, the gesture works and the difference is
        // the content — which answers #99. If neither reveals anything, the
        // swipe is not landing and the owner's empty slot proves nothing.
        //
        // An in-process probe failed to answer this exact question BECAUSE it
        // had no positive control: its known-good Button also came back empty,
        // so its empty results meant nothing. Same mistake is cheap to repeat.
        //
        // Safe only because `allowsFullSwipe: false`: the action reveals and
        // nothing fires until a button is tapped. Nothing here taps one.
        let adminRow = app.descendants(matching: .other)
            .matching(NSPredicate(format: "label CONTAINS %@", "Администратор"))
            .firstMatch
        if adminRow.waitForExistence(timeout: 5) {
            adminRow.swipeLeft()
            Thread.sleep(forTimeInterval: 1)
            // THE POSITIVE CONTROL, asserted. Without this the line above is
            // worthless: an empty slot and a swipe that never landed look
            // identical, which is precisely how the earlier probe went wrong.
            XCTAssertTrue(app.buttons["Деактивирай"].exists,
                          "the control swipe revealed nothing either — the gesture is not "
                          + "landing, so nothing can be concluded about the owner's row")
            capture("12-admin-control-swiped", app: app)
            adminRow.swipeRight()
            Thread.sleep(forTimeInterval: 1)
        } else {
            print("SKIPPED the positive control: no hittable «Администратор» row at this "
                  + "text size. The owner-row assertion above already passed, which it "
                  + "could not have done if the gesture were not landing.")
        }

        goBack(app, to: "Админ")
        dismissSheet(app, named: "Админ")
    }

    /// Профил (agri-saas#1193 P2.8): the shared account card, the person's
    /// farms (agrent-ios#179) and the «Изход» row — reached the one way there
    /// is since 2026-10-07, the menu's «Админ» and then the account card at
    /// its top.
    ///
    /// ── The farms are FOUND, never tapped ──
    ///
    /// `me-farms.json` lists the fixture farm and an invented second one. The
    /// second has no fixtures; a tap would rebuild every tab for a farm whose
    /// every path is `NO_FIXTURE`, and the rest of the run would photograph
    /// error states.
    ///
    /// ── «Изход» is FOUND, never tapped ──
    ///
    /// Its existence is asserted so the capture is known to show it; the tap
    /// would ask the confirmation, and the confirmation's answer clears the
    /// Keychain on a simulator that may be the owner's. `tapMenuRow` refuses
    /// the label outright, and nothing here calls `.tap()` on the row.
    ///
    /// The card is the same `AccountCard` Админ draws, so the same sentence is
    /// asserted: one VoiceOver stop, on the fixture account. It is tapped on
    /// Админ — the card is the row — and found again on Профил.
    private func captureProfile(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Профил")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        XCTAssertTrue(app.navigationBars["Админ"].waitForExistence(timeout: 20),
                      "Админ did not present a sheet")

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@",
                                  "Вписан като Иван Фикстуров, owner@example.invalid"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no account card on Админ")
        card.tap()
        XCTAssertTrue(app.navigationBars["Профил"].waitForExistence(timeout: 10),
                      "Админ's account card did not push Профил")

        XCTAssertTrue(card.waitForExistence(timeout: 10), "no account card on Профил")
        // The page as it opens, then the rows below it. At AX5 the farms and
        // «Изход» are below the fold and SwiftUI's `List` has not built them
        // yet, so each is REVEALED rather than expected — and photographed
        // from the top, as every other capture is.
        Thread.sleep(forTimeInterval: 2)
        capture("16-profile", app: app)
        let openFarm = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Синтетично стопанство"))
            .firstMatch
        if reveal(openFarm, in: app, what: "the open farm on Профил") {
            XCTAssertTrue(openFarm.isSelected, "the open farm is not marked as the open one")
        }
        let secondFarm = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Второ синтетично стопанство"))
            .firstMatch
        // At an accessibility size the farms were below the first capture's
        // fold, so they get one of their own — the rows' own layout, where a
        // long one-word role or name is what breaks first. At the other
        // sizes the first capture already shows them.
        if reveal(secondFarm, in: app, what: "the second fixture farm on Профил"),
           UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            Thread.sleep(forTimeInterval: 1)
            capture("16b-profile-farms", app: app)
        }
        _ = reveal(app.buttons["Изход"], in: app, what: "«Изход» on Профил")
        goBack(app, to: "Админ")
        dismissSheet(app, named: "Админ")
    }

    /// «Добави стопанство» (agrent-ios#179): the wizard's first step and the
    /// физическо лице path's name step, reached as a person reaches them —
    /// Меню → Админ → the account card → Профил. The row shows because the
    /// fixture `/me` turns `social.farm-registration` on.
    ///
    /// ── «Готово» is NEVER tapped ──
    ///
    /// It creates a REAL farm. Under the seam the POST is a 501 that never
    /// leaves the process; the suite does not rely on that, as the header
    /// says. «Отказ» closes the sheet without a write.
    private func captureFarmWizard(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for the farm wizard")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        XCTAssertTrue(app.navigationBars["Админ"].waitForExistence(timeout: 20),
                      "Админ did not present a sheet")
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@",
                                  "Вписан като Иван Фикстуров, owner@example.invalid"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no account card on Админ")
        card.tap()
        XCTAssertTrue(app.navigationBars["Профил"].waitForExistence(timeout: 10),
                      "Админ's account card did not push Профил")

        // REVEALED, not waited for (#204). Профил opens at its top, and at
        // AX5 the row is below the fold — a lazy List keeps it out of the
        // accessibility tree until scrolled to, so a wait alone failed the
        // whole variant. At a non-accessibility size a miss still fails.
        let add = app.buttons["Добави стопанство"]
        guard reveal(add, in: app, what: "«Добави стопанство» on Профил — is the fixture flag on?") else {
            goBack(app, to: "Админ")
            dismissSheet(app, named: "Админ")
            return
        }
        add.tap()
        XCTAssertTrue(app.staticTexts["Какво е стопанството Ви?"].waitForExistence(timeout: 10),
                      "the wizard did not open on its first step")
        Thread.sleep(forTimeInterval: 1)
        capture("17-farm-wizard", app: app)

        let individual = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Земеделски стопанин"))
            .firstMatch
        XCTAssertTrue(individual.waitForExistence(timeout: 5), "no физическо лице choice")
        individual.tap()
        XCTAssertTrue(app.staticTexts["Име на стопанството"].waitForExistence(timeout: 10),
                      "the физическо лице path did not go straight to the name")
        Thread.sleep(forTimeInterval: 1)
        capture("17b-farm-wizard-name", app: app)

        let cancel = app.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the wizard sheet has no «Отказ»")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Профил"].waitForExistence(timeout: 10),
                      "«Отказ» did not close the wizard")
        goBack(app, to: "Админ")
        dismissSheet(app, named: "Админ")
    }

    // MARK: - helpers

    /// The seam is ON — checked from what is on screen, since this process
    /// cannot read the app's `UITestSeam.isActive`.
    ///
    /// Two signals, because each alone is ambiguous:
    ///
    ///   1. NOT `SignInView`. Under the seam `AgrentApp.openingState` is
    ///      `.signedIn` whatever the Keychain holds, so «Вход» on screen means
    ///      the argument did not arrive — most likely `seamArgument` has
    ///      drifted from `UITestSeam.launchArgument`.
    ///   2. The FIXTURE journal. A simulator that happens to hold the owner's
    ///      real token would pass (1) with the seam OFF and photograph
    ///      production — the exact thing #115 moved away from. `journal-list.
    ///      json` carries a type this build does not know, rendered «Друг вид»,
    ///      which the live tenant's journal does not contain. Seeing it is the
    ///      evidence this is the fixture world.
    private func assertSeamActive(_ app: XCUIApplication) {
        // A short wait ON PURPOSE: the thing being ruled out.
        if app.buttons["Вход с Google"].waitForExistence(timeout: 3) {
            XCTFail("""
            The app is on SignInView, so the UI test seam is OFF.

            This suite launches with `\(Self.seamArgument)`, which must equal \
            `UITestSeam.launchArgument` in Agrent/Debug/UITestSeam.swift, and \
            the app must be a DEBUG build — the seam is compiled out of Release.
            """)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15),
                      "no tab bar appeared within 15s")
    }

    /// Signal (2) above, run AFTER the Дневник capture because it scrolls.
    ///
    /// The «Друг вид» row is the fifth of five, and at AX5 a SwiftUI `List`
    /// has not created a row that far below the fold — so it is looked for
    /// with up to six swipes rather than waited on. Дневник has no swipe
    /// actions, so a swipe here can only scroll. Left scrolled: every later
    /// step starts from the navigation bar or the tab bar, which do not move.
    private func assertFixtureWorld(_ app: XCUIApplication) {
        let fixtureRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Друг вид"))
            .firstMatch
        _ = fixtureRow.waitForExistence(timeout: 5)
        for _ in 0..<6 where !fixtureRow.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(fixtureRow.exists, """
            Дневник does not show journal-list.json's «Друг вид» row, so this may \
            be the LIVE tenant rather than the fixture seam. Stopping before \
            anything is opened: the messaging captures below are safe only \
            under the seam.
            """)
    }

    /// The ambient settings go in the NAME, read back from the runner rather
    /// than passed in by the script that set them.
    ///
    /// The script sets `simctl ui content_size` and `increase_contrast` and
    /// then names its output directory after what it asked for. If a set ever
    /// silently fails, a directory called `ax5` would fill up with default-size
    /// screenshots and nothing would say so. The runner is an app on the same
    /// device, so it reads the same settings the app under test reads, and a
    /// mismatch between the directory and the file name inside it IS the
    /// report.
    // MARK: - «Проверка» with no signal (agrent-ios#384)

    /// «Ново мероприятие» walked to «Проверка» twice: once with the fixtures
    /// answering, which also caches every read the flow makes, then on a
    /// second launch where every request fails as it does in Airplane mode.
    /// On the owner's phone the second walk ended on an empty page with only
    /// a back arrow (2026-10-21). Nothing is saved: «Отказ» on «Проверка»,
    /// and the seam refuses writes anyway.
    func testTreatmentCheckWithNoSignal() {
        let online = XCUIApplication()
        online.launchArguments.append(Self.seamArgument)
        online.launch()
        assertSeamActive(online)
        walkToCheck(online, named: "20-treatment-check-online")
        online.terminate()

        let offline = XCUIApplication()
        offline.launchArguments += [Self.seamArgument, Self.offlineArgument]
        offline.launch()
        XCTAssertTrue(offline.tabBars.firstMatch.waitForExistence(timeout: 20),
                      "no tab bar with no signal")
        // The seam's limit, not the phone's. Under the seam the identity is
        // memory-only and learned from the fixture `/me` after launch, so
        // Дневник's first read has no cache scope yet and fails. A phone has
        // its identity in the Keychain before the first read (the owner's
        // #113 check 1: cached data on a cold launch). One retry, once the
        // identity is known, reads the cache as the phone would at once.
        let retry = offline.buttons["Опитай пак"]
        if retry.waitForExistence(timeout: 5) { retry.tap() }
        walkToCheck(offline, named: "20b-treatment-check-offline")
    }

    /// Дневник → «Нов запис» → «Торене», a new fertiliser, a dose and a unit
    /// → «Напред» → the one crop's parcels, all chosen → «Продължи», then
    /// asserts that «Проверка» shows its read-back.
    private func walkToCheck(_ app: XCUIApplication, named name: String) {
        let open = app.buttons["Нов запис"]
        let launched = Date()
        let found = open.waitForExistence(timeout: 30)
        capture("\(name)-start", app: app)
        XCTAssertTrue(found, "no «Нов запис» on Дневник\n\(app.debugDescription)")
        // How long Дневник took to offer it, in the log: #113 measured a
        // 16-second stall on a cold launch with no signal once.
        print("A11Y-TIMING \(name): «Нов запис» after \(Int(Date().timeIntervalSince(launched)))s")
        open.tap()

        // «Вид» is a menu since #439 (five kinds), named by its title as the
        // unit's is.
        let kind = app.buttons["Вид"]
        XCTAssertTrue(kind.waitForExistence(timeout: 10), "no «Вид» on step one\n\(app.debugDescription)")
        kind.tap()
        let fertilise = app.buttons["Торене"]
        XCTAssertTrue(fertilise.waitForExistence(timeout: 5), "no «Торене» in «Вид»")
        fertilise.tap()

        let product = app.textFields["Търговско наименование"]
        XCTAssertTrue(product.waitForExistence(timeout: 5), "no product field")
        product.tap()
        product.typeText("Синтетичен тор")

        let dose = app.textFields["Количество"].exists ? app.textFields["Количество"] : app.textFields["0"]
        XCTAssertTrue(dose.waitForExistence(timeout: 5), "no dose field\n\(app.debugDescription)")
        dose.tap()
        dose.typeText("10")

        let unit = app.buttons["Мерна единица"]
        if !unit.isHittable { app.swipeUp() }
        XCTAssertTrue(unit.waitForExistence(timeout: 5), "no unit picker\n\(app.debugDescription)")
        unit.tap()
        let kg = app.buttons["кг/дка"]
        XCTAssertTrue(kg.waitForExistence(timeout: 5), "no «кг/дка» in the unit menu\n\(app.debugDescription)")
        kg.tap()

        let next = app.buttons["Напред"]
        if !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no «Напред»")
        next.tap()

        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Избери всички'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 15), "no parcels on «Къде»\n\(app.debugDescription)")
        all.tap()
        // The target button on step two's map (#398): one press frames the
        // next parcel.
        let target = app.buttons["Следващ парцел"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no target button on «Къде»")
        target.tap()
        capture("\(name)-place-target", app: app)

        let proceed = app.buttons["Продължи"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5), "no «Продължи»")
        proceed.tap()

        let add = app.buttons["Добави"]
        let shown = add.waitForExistence(timeout: 10)
        capture(name, app: app)
        XCTAssertTrue(shown, "«Проверка» is empty: no «Добави»\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Изчислено"].exists || app.staticTexts["ИЗЧИСЛЕНО"].exists,
                      "«Проверка» has no read-back")
        let cancel = app.navigationBars.buttons["Отказ"]
        if cancel.exists { cancel.tap() }
    }

    // MARK: - Риск: «История» opens the history (agrent-ios#386)

    /// The owner tapped «История» on a risk row and nothing happened
    /// (2026-10-21). The button pushed through a `pushRoute` read from
    /// outside the stack. This opens Риск from the menu, as the owner does,
    /// taps the first row's «История», and asserts that the history screen
    /// came up.
    func testRiskHistoryOpens() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root")
        XCTAssertTrue(tapMenuRow("Риск", in: app), "«Риск» is not in the menu")
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'История на парцел'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 20), "no «История» on a risk row\n\(app.debugDescription)")
        history.tap()
        let opened = app.navigationBars["История"].waitForExistence(timeout: 10)
        capture("05b-risk-history", app: app)
        XCTAssertTrue(opened, "«История» did not open the parcel's history\n\(app.debugDescription)")
        // The floating action: bottom LEFT since the assistant took the
        // right (owner, 2026-11-01).
        app.navigationBars.buttons.firstMatch.tap()
        let insure = app.buttons["Застраховай"]
        XCTAssertTrue(insure.waitForExistence(timeout: 5), "no «Застраховай»")
        XCTAssertLessThan(insure.frame.midX, app.windows.firstMatch.frame.midX,
                          "«Застраховай» is not on the left")
        capture("05c-risk-insure", app: app)
    }

    // MARK: - Борса: the map filters the board (agrent-ios#417)

    /// Борса → «Покажи карта» → Плевен: the oblast turns green, the summary
    /// says «Област: Плевен», and the board under the map is the filter's
    /// answer. Ends on the list with no filter, since the view is remembered.
    func testExchangeMapFiltersByRegion() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let tab = labelled("Борса", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Борса» tab")
        tab.tap()
        let toMap = app.buttons["Покажи карта"]
        if toMap.waitForExistence(timeout: 10) { toMap.tap() }
        // The map's proxy is the Button; the region row under the map has
        // the same words and no action.
        let pleven = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Плевен'")).firstMatch
        XCTAssertTrue(pleven.waitForExistence(timeout: 15), "no Плевен on the map\n\(app.debugDescription)")
        pleven.tap()
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Област: Плевен'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the tap did not filter\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("06b-exchange-map-filtered", app: app)

        app.buttons["Изчисти областите"].firstMatch.tap()
        XCTAssertFalse(summary.waitForExistence(timeout: 3), "«Изчисти» left the filter on")
        let toList = app.buttons["Покажи списък"]
        if toList.waitForExistence(timeout: 5) { toList.tap() }
    }

    // MARK: - Калкулатор: «Всички» or one crop (owner 2026-10-24)

    /// The dropdown, «Всички» with the farm block on top and every crop under
    /// it, then one crop alone. Ends back on «Всички», since the choice is
    /// remembered across launches and the next run should start where this
    /// one did.
    func testCalculatorAllAndOneCrop() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        tab.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Култура:'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "no crop dropdown\n\(app.debugDescription)")

        choose("Всички", from: picker, in: app)
        XCTAssertTrue(app.staticTexts["Общо за стопанството"].waitForExistence(timeout: 5),
                      "«Всички» has no farm block\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09c-calculator-all", app: app)

        choose("Пшеница", from: picker, in: app)
        XCTAssertTrue(app.buttons["Култура: Пшеница"].waitForExistence(timeout: 5),
                      "the dropdown does not say «Пшеница»\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Общо за стопанството"].exists, "one crop shows no farm block")
        Thread.sleep(forTimeInterval: 1)
        capture("09d-calculator-one-crop", app: app)

        choose("Всички", from: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Култура:'")).firstMatch,
               in: app)
    }

    /// Opens a SwiftUI `Menu` and taps one of its items, waiting for the menu
    /// to animate in — an immediate tap finds nothing.
    private func choose(_ item: String, from menu: XCUIElement, in app: XCUIApplication) {
        menu.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label == %@", item)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the menu has no «\(item)»\n\(app.debugDescription)")
        entry.tap()
    }

    // MARK: - Тенденции: one price, one line, one row (agrent-ios#409)

    /// The owner's screenshot had a chart with no number above it and a
    /// quotation list under it. Now: the price large, its change, the line,
    /// and one row saying whose price it is.
    func testTrendsShowsOnePrice() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root")
        XCTAssertTrue(tapMenuRow("Тенденции", in: app), "«Тенденции» is not in the menu")
        let price = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH '208,62' AND label CONTAINS 'евро на тон'")).firstMatch
        XCTAssertTrue(price.waitForExistence(timeout: 20), "no headline price\n\(app.debugDescription)")
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'България'")).count
        XCTAssertEqual(source, 1, "one info row under the chart, not a legend\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("07a-trends-one-price", app: app)
    }

    // MARK: - «Нова задача» → «Парцели» (agrent-ios#388)

    /// Задачи → + → a title → «Напред» → «Парцели»: the fixture farm's one
    /// block is chosen for the person, its parcels are listed, and choosing
    /// all of them is counted at the bottom. Stops before «Създай»: nothing
    /// is written, and the seam refuses writes anyway.
    func testNewTaskParcelsStep() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        app.tabBars.buttons["Задачи"].tap()
        let plus = app.buttons["Нова задача"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "no + on Задачи")
        plus.tap()
        // The sheet has to be IN the accessibility tree, which it wasn't
        // while the + sat in an `.overlay` (#388): this is the assertion
        // that caught it.
        XCTAssertTrue(app.navigationBars["Нова задача"].waitForExistence(timeout: 10),
                      "«Нова задача» is not in the accessibility tree")
        // The first field on the form; the description is the second.
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no «Заглавие»\n\(app.debugDescription)")
        title.tap()
        title.typeText("Синтетична задача")
        app.buttons["Напред"].tap()
        XCTAssertTrue(app.navigationBars["Парцели"].waitForExistence(timeout: 10), "«Напред» opened no «Парцели»")
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Избери всички'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 15), "the one block's parcels weren't listed\n\(app.debugDescription)")
        all.tap()
        let counted = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'към задачата.'")).firstMatch
        XCTAssertTrue(counted.waitForExistence(timeout: 5), "the chosen parcels aren't counted")
        XCTAssertTrue(app.buttons["Създай"].exists, "no «Създай» on «Парцели»")
        capture("08e-new-task-parcels", app: app)
    }

    // MARK: - «Виж на картата» on a recorded treatment (agrent-ios#399)

    /// Дневник → the fixture treatment («Тестов хербицид») → «Виж на картата»:
    /// its three parcels on a map and in a list, then one press of the
    /// target button.
    func testTreatmentMapFromTheJournal() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тестов хербицид'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no fixture treatment on Дневник")
        row.tap()
        let open = app.buttons["Виж на картата"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the treatment has no «Виж на картата»\n\(app.debugDescription)")
        open.tap()
        XCTAssertTrue(app.navigationBars["Третирани парцели"].waitForExistence(timeout: 10),
                      "«Виж на картата» opened no map\n\(app.debugDescription)")
        let parcel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SYNTH-1'")).firstMatch
        XCTAssertTrue(parcel.waitForExistence(timeout: 10), "the treated parcels aren't listed\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2)
        capture("01f-treatment-map", app: app)
        let target = app.buttons["Следващ парцел"]
        XCTAssertTrue(target.exists, "no target button on the treatment's map")
        target.tap()
        Thread.sleep(forTimeInterval: 1)
        capture("01g-treatment-map-target", app: app)
    }

    /// #395: a treatment's «Изтрий», the question before it (owner,
    /// 2026-10-26), and the bar's «Отмени» (no «Кошче» since #411: what's
    /// deleted is deleted). The
    /// undo comes inside the window, so no delete is ever built; one that
    /// were would meet the seam's refusal of every write, never a server.
    func testSwipeDeleteAndUndo() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тестов хербицид'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no fixture treatment on Дневник")
        row.swipeLeft()
        let delete = app.buttons["Изтрий"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the swipe offered no «Изтрий»\n\(app.debugDescription)")
        capture("01h-journal-swipe", app: app)
        delete.tap()
        // Asked first (owner, 2026-10-26): nothing goes until the question's
        // own «Изтрий».
        let question = app.alerts["Сигурни ли сте, че искате да изтриете записа?"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "«Изтрий» asked nothing\n\(app.debugDescription)")
        XCTAssertTrue(row.exists, "the row went before the question was answered")
        capture("01h2-journal-swipe-confirm", app: app)
        question.buttons["Отказ"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "«Отказ» removed the row")
        XCTAssertFalse(app.buttons["Отмени"].exists, "«Отказ» started the five seconds")
        row.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the second swipe offered no «Изтрий»")
        delete.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 3), "the second «Изтрий» asked nothing")
        question.buttons["Изтрий"].tap()
        let undo = app.buttons["Отмени"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no «Отмени» after «Изтрий»\n\(app.debugDescription)")
        XCTAssertFalse(row.exists, "the row stayed in the list")
        capture("01i-journal-undo", app: app)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "«Отмени» did not bring the row back")

        XCTAssertFalse(app.buttons["Кошче"].exists, "«Кошче» was removed (#411)")
    }

    /// «Документи» (#468, owner 2026-10-30), from the menu: a synthetic
    /// library in every state a row can be in, the upload's choices, a
    /// document's «Изтрий» with its question and «Отмени» (inside the
    /// window, so no delete is built), and the settings at the bottom.
    func testDocuments() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(openMenu(app), "no «Меню» on the root")
        XCTAssertTrue(tapMenuRow("Документи", in: app), "«Документи» is not in the menu")
        XCTAssertTrue(app.navigationBars["Документи"].waitForExistence(timeout: 15), "the menu opened no «Документи»")
        let live = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Сертификат за семена'")).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 15), "no fixture document\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Изтрит документ'")).firstMatch.exists,
                      "the deleted document's tombstone is not listed")
        XCTAssertTrue(app.buttons["Сканирай"].exists, "no camera button at the top right")
        Thread.sleep(forTimeInterval: 1)
        capture("21-documents", app: app)

        app.buttons["Качи документ"].tap()
        XCTAssertTrue(app.buttons["От файловете"].waitForExistence(timeout: 5), "the upload offers no choices")
        capture("21b-documents-upload", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()

        live.swipeLeft()
        let delete = app.buttons["Изтрий"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the document offered no «Изтрий»")
        delete.tap()
        let question = app.alerts["Сигурни ли сте, че искате да изтриете документа?"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "«Изтрий» asked nothing")
        question.buttons["Изтрий"].tap()
        let undo = app.buttons["Отмени"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no «Отмени» after «Изтрий»")
        capture("21c-documents-undo", app: app)
        undo.tap()
        XCTAssertTrue(live.waitForExistence(timeout: 5), "«Отмени» did not bring the document back")

        // Down to the settings: a List reports a row past the fold as
        // hittable, so the swipes are not conditional on it.
        for _ in 0..<3 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        let settings = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Копие в Google Drive'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Drive switch under the list\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("21d-documents-settings", app: app)
    }

    /// «Известия» (#471, owner 2026-10-30), from the menu, whose row carries
    /// the unread count: the list, then a task's notification opening the
    /// task. Marking it read is a write, which the seam refuses, so the list
    /// reads again and keeps it unread: no write is ever made.
    func testNotifications() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(openMenu(app), "no «Меню» on the root")
        let row = app.buttons["Известия (2)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the menu has no «Известия (2)»\n\(app.debugDescription)")
        capture("22-notifications-menu", app: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Известия"].waitForExistence(timeout: 15), "the menu opened no «Известия»")
        let task = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ново, Възложена ви е задача'")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10), "no unread task notification\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("22b-notifications", app: app)
        task.tap()
        XCTAssertTrue(app.staticTexts["Заявка за анализ на почвата"].waitForExistence(timeout: 15),
                      "the task notification opened no task\n\(app.debugDescription)")

        // A Борса message opens its conversation (#473).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let message = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ново съобщение в Борса'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "no Борса notification\n\(app.debugDescription)")
        message.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'пшеницата още ли е налична'")).firstMatch
            .waitForExistence(timeout: 15), "the Борса notification opened no conversation\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("22c-notification-thread", app: app)
    }

    /// Your own listing from «Моите обяви» (#478, owner 2026-10-31): the
    /// active row opens the listing's screen, which offers «Изпълнена» and
    /// «Оттегли»; «Оттегли» asks first. The question is photographed and
    /// answered «Отказ» — confirming is a write that takes a listing off the
    /// board, and the first real one is the owner's.
    func testMyListingOpensWithItsMoves() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(app.tabBars.buttons["Борса"].waitForExistence(timeout: 15), "no «Борса» in the tab bar")
        app.tabBars.buttons["Борса"].tap()
        let mine = app.buttons["Моите обяви"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "no «Моите обяви» on Борса")
        mine.tap()
        let active = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Активна'")).firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 15), "no active row in «Моите обяви»\n\(app.debugDescription)")
        active.tap()
        let withdraw = app.buttons["Оттегли"]
        XCTAssertTrue(withdraw.waitForExistence(timeout: 10), "the listing offers no «Оттегли»\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Изпълнена"].exists, "the listing offers no «Изпълнена»")
        // Below the fold, under the tab bar: the facts come first.
        for _ in 0..<4 where !withdraw.isHittable { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        capture("09d-my-listing", app: app)
        withdraw.tap()
        // iOS 26 draws the question as a popover on the button, without
        // «Отказ»: a tap outside it is the way out, and the only one taken.
        let question = app.sheets["Да се оттегли ли обявата?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "«Оттегли» asked nothing\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09e-my-listing-withdraw", app: app)
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists { outside.tap() } else { app.buttons["Отказ"].tap() }
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "the question did not go away")
        XCTAssertTrue(withdraw.exists, "leaving the question left the listing")

        // The pencil (#478): the form with the listing's stored values,
        // photographed and left with «Отказ» — «Запази» is a write.
        let pencil = app.buttons["Редактирай"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5), "no pencil on your own listing\n\(app.debugDescription)")
        pencil.tap()
        XCTAssertTrue(app.navigationBars["Редактиране"].waitForExistence(timeout: 10)
                      || app.staticTexts["Редактиране"].waitForExistence(timeout: 2),
                      "the pencil opened no form\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Запази"].exists, "the form has no «Запази»")
        Thread.sleep(forTimeInterval: 1)
        capture("09f-my-listing-edit", app: app)
        app.buttons["Отказ"].firstMatch.tap()
        XCTAssertTrue(pencil.waitForExistence(timeout: 5), "«Отказ» did not close the form")
    }

    /// A MECHANISATOR's one screen (#465, owner 2026-10-29): no tab bar, the
    /// farm's map with the person's task count on SYNTH-1, their current
    /// tasks under it (the queue fixture's closed row left out), the
    /// parcels list, and a parcel opened from it onto its risk and tasks.
    /// Then the menu: Риск and Админ, no Блокове or Задачи.
    func testMechanisatorHome() {
        let app = XCUIApplication()
        app.launchArguments += [Self.seamArgument, Self.operatorArgument]
        app.launch()
        XCTAssertFalse(app.buttons["Вход с Google"].waitForExistence(timeout: 3), "the seam is off")
        XCTAssertTrue(app.navigationBars["Моите задачи"].waitForExistence(timeout: 20),
                      "a mechanisator did not open on «Моите задачи»\n\(app.debugDescription)")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a mechanisator has no tab bar")

        let task = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Пръскане срещу плевели")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15), "the queue's current task is not listed")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Почистване на синтетичен канал")).firstMatch.exists,
                       "a closed task is listed as current")
        // On the MAP, not the parcels row with the same words: the row is a
        // button and the number on the map is not.
        let badge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType != %d",
                                  "SYNTH-1, 2 задачи", XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 15),
                      "SYNTH-1 carries no «2 задачи» on the map\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2)
        capture("20-mechanisator-home", app: app)

        // The parcels list, under the tasks: dragged on the list, as a swipe
        // from the middle could land on the map and pan it.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTH-1, 2 задачи")).firstMatch
        for _ in 0..<4 where !(row.exists && row.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no «Парцели» row for SYNTH-1")
        capture("20b-mechanisator-parcels", app: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10), "the parcel row opened no screen")
        let tasksCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Задачи, 2 текущи")).firstMatch
        XCTAssertTrue(tasksCard.waitForExistence(timeout: 10), "the parcel's screen has no «Задачи»")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Коментари, 2 коментара")).firstMatch
            .waitForExistence(timeout: 10), "the parcel's screen has no «Коментари»")
        Thread.sleep(forTimeInterval: 1)
        capture("20c-mechanisator-parcel", app: app)
        app.navigationBars["История"].buttons.firstMatch.tap()

        XCTAssertTrue(openMenu(app), "no «Меню» on the mechanisator's screen")
        XCTAssertTrue(labelled("Риск", in: app.buttons).waitForExistence(timeout: 5), "«Риск» is not in the menu")
        XCTAssertTrue(labelled("Админ", in: app.buttons).exists, "«Админ» is not in the menu")
        XCTAssertFalse(labelled("Блокове", in: app.buttons).exists, "«Блокове» is in the menu")
        XCTAssertFalse(labelled("Известия", in: app.buttons).exists, "a mechanisator has «Известия» (#471: outside the operator allowlist)")
        XCTAssertFalse(labelled("Документи", in: app.buttons).exists, "a mechanisator has «Документи» (#468: no access)")
        Thread.sleep(forTimeInterval: 1)
        capture("20d-mechanisator-menu", app: app)
    }

    /// «Тема» in Админ, light then dark then back (owner, 2026-10-29), and the
    /// section titles in gold, «Разходи» on Калкулатор with the cost names
    /// under it in the row's own colour. Ends on «Автоматично», as the
    /// choice is remembered across launches and the next run should start
    /// where this one did.
    func testThemeAndGoldSectionTitles() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Админ")
        XCTAssertTrue(tapMenuRow("Админ", in: app), "«Админ» is not in the menu")
        let dark = app.buttons["Тъмна"]
        XCTAssertTrue(dark.waitForExistence(timeout: 15), "Админ has no «Тема»\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Светла"].exists && app.buttons["Автоматично"].exists)
        app.buttons["Светла"].tap()
        Thread.sleep(forTimeInterval: 1)
        capture("10c-admin-theme-light", app: app)
        dark.tap()
        Thread.sleep(forTimeInterval: 1)
        capture("10d-admin-theme-dark", app: app)
        app.buttons["Автоматично"].tap()
        Thread.sleep(forTimeInterval: 1)
        // Out of Админ by its own «Затвори»: a swipe-down dismissal is still
        // animating when the tab is tapped, and that tap is dropped.
        app.navigationBars.buttons["Затвори"].firstMatch.tap()
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        Thread.sleep(forTimeInterval: 1)
        tab.tap()
        let fertiliser = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Торове")).firstMatch
        var swipes = 0
        while !fertiliser.exists, swipes < 8 { app.swipeUp(); Thread.sleep(forTimeInterval: 0.5); swipes += 1 }
        XCTAssertTrue(fertiliser.exists, "the calculator lists no costs\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09f-calculator-section-titles-gold", app: app)
    }

    /// #454: a task's «Изтрий», the question, and the bar's «Отмени»
    /// (owner, 2026-10-26). The undo comes inside the window, so no delete is
    /// ever built; one that were would meet the seam's refusal of every write.
    func testTaskSwipeDeleteAndUndo() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let tab = labelled("Задачи", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Задачи» tab")
        tab.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Смяна на масло'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no fixture task on Задачи\n\(app.debugDescription)")
        row.swipeLeft()
        let delete = app.buttons["Изтрий"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the swipe offered no «Изтрий»\n\(app.debugDescription)")
        capture("08e-task-swipe", app: app)
        delete.tap()
        let question = app.alerts["Сигурни ли сте, че искате да изтриете задачата?"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "«Изтрий» asked nothing\n\(app.debugDescription)")
        XCTAssertTrue(row.exists, "the task went before the question was answered")
        capture("08f-task-swipe-confirm", app: app)
        question.buttons["Изтрий"].tap()
        let undo = app.buttons["Отмени"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no «Отмени» after «Изтрий»\n\(app.debugDescription)")
        XCTAssertFalse(row.exists, "the task stayed in the list")
        capture("08g-task-undo", app: app)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "«Отмени» did not bring the task back")
    }

    /// An expense swiped away in Калкулатор (#481, owner 2026-10-31):
    /// «Изтрий», the question, the row gone with «Отмени», and «Отмени»
    /// bringing it back inside the five seconds — so nothing is ever sent.
    func testCostSwipeDeleteAndUndo() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        tab.tap()
        // Folded by type since #500: «Торове» opens first.
        let type = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Торове, 2 записа'")).firstMatch
        for _ in 0..<8 where !(type.exists && type.isHittable) { app.swipeUp() }
        XCTAssertTrue(type.waitForExistence(timeout: 15), "no «Торове» type row\n\(app.debugDescription)")
        type.tap()
        // By its amount: «Торове, 1 запис» is the type row once one is gone.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Торове, 1779'")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no fixture expense in «Разходи»\n\(app.debugDescription)")
        // The unfold animates, and a swipe that lands during it is lost:
        // one more try before calling it a failure.
        Thread.sleep(forTimeInterval: 1)
        row.swipeLeft()
        let delete = app.buttons["Изтрий"]
        if !delete.waitForExistence(timeout: 3) { row.swipeLeft() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the swipe offered no «Изтрий»\n\(app.debugDescription)")
        capture("21a-cost-swipe", app: app)
        delete.tap()
        let question = app.alerts["Сигурни ли сте, че искате да изтриете разхода?"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "«Изтрий» asked nothing\n\(app.debugDescription)")
        capture("21b-cost-swipe-confirm", app: app)
        question.buttons["Изтрий"].tap()
        let undo = app.buttons["Отмени"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no «Отмени» after «Изтрий»\n\(app.debugDescription)")
        XCTAssertFalse(row.exists, "the expense stayed in the list")
        capture("21c-cost-undo", app: app)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "«Отмени» did not bring the expense back")
    }

    /// «Разходи» by type (#500): folded, one type opened to its rows (its own
    /// month graph removed at the owner's word, 2026-11-01), the chips
    /// narrowing to one type, and the two graphs of the whole.
    func testCalculatorExpensesByType() {
        let app = XCUIApplication()
        app.launchArguments.append(Self.seamArgument)
        app.launch()
        assertSeamActive(app)
        let tab = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        tab.tap()
        let total = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Общо, 5 записа'")).firstMatch
        for _ in 0..<8 where !(total.exists && total.isHittable) { app.swipeUp() }
        XCTAssertTrue(total.waitForExistence(timeout: 15), "no «Общо» row\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09e-expenses-folded", app: app)

        let type = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Торове, 2 записа'")).firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 5), "no «Торове» type row\n\(app.debugDescription)")
        type.tap()
        Thread.sleep(forTimeInterval: 1)
        capture("09f-expenses-one-type-open", app: app)
        type.tap()

        // The type dropdown (owner, 2026-11-01): it stays open while types
        // are ticked, so it is photographed open, then closed by a tap above.
        let types = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Видове разходи:'")).firstMatch
        XCTAssertTrue(types.waitForExistence(timeout: 5), "no type dropdown\n\(app.debugDescription)")
        types.tap()
        let pesticide = app.buttons["Препарати"].firstMatch
        XCTAssertTrue(pesticide.waitForExistence(timeout: 5), "no «Препарати» in the dropdown\n\(app.debugDescription)")
        pesticide.tap()
        Thread.sleep(forTimeInterval: 1)
        capture("09g-expenses-type-menu", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let filtered = app.buttons["Видове разходи: Препарати"]
        XCTAssertTrue(filtered.waitForExistence(timeout: 5), "the dropdown does not say «Препарати»\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09g-expenses-filtered", app: app)
        filtered.tap()
        let all = app.buttons["Всички видове"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), "no «Всички видове»")
        all.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        let chart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Разходи по месеци'")).firstMatch
        for _ in 0..<8 where !(chart.exists && chart.isHittable) { app.swipeUp() }
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "no month graph\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09h-expenses-graphs", app: app)

        // The month graph's dropdown (owner, 2026-11-01): one month, by type.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Месец:'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no month dropdown\n\(app.debugDescription)")
        picker.tap()
        let october = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Октомври'")).firstMatch
        XCTAssertTrue(october.waitForExistence(timeout: 5), "no «Октомври» in the dropdown\n\(app.debugDescription)")
        october.tap()
        let oneMonth = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Разходи за октомври'")).firstMatch
        XCTAssertTrue(oneMonth.waitForExistence(timeout: 5), "the graph did not show one month\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("09i-expenses-one-month", app: app)
    }

    /// The assistant (#483): its button lower right, above Калкулатор's
    /// «Нов разход» and above the bar on Задачи, and its sheet over the
    /// screen. A question asked under the seam never leaves the device: the
    /// fixture protocol has no stream to answer with, so the turn ends in its
    /// Bulgarian refusal, which is photographed too.
    func testAssistantButtonAndSheet() {
        let app = XCUIApplication()
        app.launchArguments += [Self.seamArgument, "AGRENT_UITEST_ASSISTANT"]
        app.launch()
        assertSeamActive(app)
        let calculator = labelled("Калкулатор", in: app.tabBars.buttons)
        XCTAssertTrue(calculator.waitForExistence(timeout: 10), "no «Калкулатор» tab")
        calculator.tap()
        let button = app.buttons["Асистент"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no assistant button\n\(app.debugDescription)")
        let newCost = app.buttons["Нов разход"]
        XCTAssertTrue(newCost.waitForExistence(timeout: 10), "no «Нов разход»")
        XCTAssertLessThan(button.frame.maxY, newCost.frame.minY, "the button sits on «Нов разход»")
        Thread.sleep(forTimeInterval: 1)
        capture("23a-assistant-button", app: app)

        let tasks = labelled("Задачи", in: app.tabBars.buttons)
        tasks.tap()
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no assistant button on Задачи")
        Thread.sleep(forTimeInterval: 1)
        capture("23b-assistant-button-tasks", app: app)

        button.tap()
        let field = app.textFields["Въпрос"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet has no question field\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1)
        capture("23c-assistant-sheet", app: app)
        field.tap()
        field.typeText("Колко задачи имам тази седмица?")
        app.buttons["Попитай"].tap()
        Thread.sleep(forTimeInterval: 2)
        capture("23d-assistant-turn", app: app)
    }

    /// The assistant's button holds the bottom right on every screen; the
    /// screens' own floating buttons must not sit under it (owner,
    /// 2026-11-01: «Нова задача» and «Застраховай» to the bottom left). On a
    /// block's map, the map's own two buttons must stay clear of it too.
    func testFloatingButtonsKeepClearOfTheAssistant() {
        let app = XCUIApplication()
        app.launchArguments += [Self.seamArgument, "AGRENT_UITEST_ASSISTANT"]
        app.launch()
        assertSeamActive(app)
        let assistant = app.buttons["Асистент"]

        let tasks = labelled("Задачи", in: app.tabBars.buttons)
        XCTAssertTrue(tasks.waitForExistence(timeout: 10), "no «Задачи» tab")
        tasks.tap()
        let newTask = app.buttons["Нова задача"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 15), "no «Нова задача»\n\(app.debugDescription)")
        XCTAssertTrue(assistant.waitForExistence(timeout: 10), "no assistant button on Задачи")
        XCTAssertLessThan(newTask.frame.midX, app.windows.firstMatch.frame.midX, "«Нова задача» is not on the left")
        XCTAssertFalse(newTask.frame.intersects(assistant.frame), "«Нова задача» sits under the assistant")
        Thread.sleep(forTimeInterval: 1)
        capture("24a-floating-tasks", app: app)

        app.tabBars.buttons["Блокове"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20), "Блокове showed no rows")
        app.cells.firstMatch.tap()
        let target = app.buttons["Следващ парцел"]
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no target button on the map\n\(app.debugDescription)")
        let locate = app.buttons["Моето местоположение"]
        XCTAssertTrue(locate.waitForExistence(timeout: 5), "no location button on the map")
        XCTAssertTrue(assistant.waitForExistence(timeout: 10), "no assistant button on the map")
        XCTAssertFalse(target.frame.intersects(assistant.frame), "the target button sits under the assistant")
        XCTAssertFalse(locate.frame.intersects(assistant.frame), "the location button sits under the assistant")
        Thread.sleep(forTimeInterval: 3)
        capture("24b-floating-map", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let size = UIApplication.shared.preferredContentSizeCategory.rawValue
            .replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        // `UIScreen.main` is deprecated, and is still the accessor here, which
        // is a choice rather than an oversight. The runner has no view
        // hierarchy of its own worth reading, so the trait-environment
        // accessors that replace it report DEFAULTS rather than what the
        // device is set to — and a default reported as a measurement is
        // exactly the failure this naming scheme exists to catch. Measured
        // working on 2026-09-26: the filenames carry `AccessibilityXXXL`,
        // `contrast-high` and `light` correctly. If it ever goes quiet, the
        // directory name and the file name inside it stop agreeing, and that
        // disagreement is the report.
        let traits = UIScreen.main.traitCollection
        let contrast = traits.accessibilityContrast == .high ? "contrast-high" : "contrast-normal"
        let appearance = traits.userInterfaceStyle == .dark ? "dark" : "light"

        // Separated by `__` rather than by dots. XCTest treats the last
        // dot-separated component of an attachment name as a file extension
        // and rewrites it — `01-journal.L.contrast-normal.dark` came back out
        // of the result bundle as `01-journal.L.contrast-normal_0_<uuid>.dark`.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)__\(size)__\(contrast)__\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
