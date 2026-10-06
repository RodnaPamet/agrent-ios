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

        // Дневник, the launch screen. #97 asks whether a list row stacks at
        // AX sizes and whether the `·` between the values disappears with it;
        // this row is `JournalRow` → `AdaptiveRow` → `MetaRow`, the exact
        // shape PR #93 changed.
        capture("01-journal", app: app)
        assertFixtureWorld(app)
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
        captureFromMenu("06-news", label: "Новини", app: app)
        captureFromMenu("07-dashboard", label: "Табло", app: app)
        captureAdmin(app)
        captureProfile(app)

        // Задачи and Борса ARE in the default bar — but the bar is whatever the
        // server sent, so this asks the tab bar first and falls back to the
        // menu rather than assuming. A suite that assumes a tab exists reports
        // "no Задачи button" for a farm that simply arranged its bar
        // differently.
        captureTabOrMenu("08-tasks", label: "Задачи", app: app)

        // Борса, and from it the messaging screens #114 built and #115 made
        // photographable. Its own method because it goes four screens deep.
        captureExchangeAndMessaging(app)

        // Локации → a location's map: the one #97 calls "the one that matters
        // most", because Increase Contrast is what switches the near-solid
        // fill on and the label outline is the answer to it.
        XCTAssertTrue(app.tabBars.buttons["Локации"].waitForExistence(timeout: 10),
                      "no «Локации» button in the tab bar")
        app.tabBars.buttons["Локации"].tap()

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
        // modes are a MapKit view and the schematic is a `Canvas`, and both
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

        captureSchematicMap(app)
    }

    /// The schematic map, which is up to two taps away and is the one #97
    /// cares about.
    ///
    /// `ParcelMapView` defaults to `.precise` — true outlines over Apple's
    /// imagery — and the toolbar button CYCLES precise → simplified →
    /// schematic → precise (`ParcelMapMode.next`). The white parcel labels
    /// whose contrast PR #93 measured at 3.93:1, and 3.20:1 once Increase
    /// Contrast switches the near-solid fill on, are drawn by the schematic
    /// `Canvas` and by nothing else. Stopping at the satellite map would
    /// photograph the wrong screen.
    ///
    /// The button's accessibility label is the mode it takes you TO, so the
    /// mode the screen is IN is read off the label rather than counted in
    /// taps: the button offers «Точни очертания» exactly when the schematic
    /// is on screen.
    ///
    /// WHICH IS NOT A REFINEMENT — IT IS A BUG THIS HAD. `mode` is
    /// `@AppStorage`, so it survives the run, and the first version tapped
    /// twice from an assumed `.precise` start. The fourth variant in
    /// `scripts/a11y-shots.sh` then failed with "no «Опростена» button in the
    /// toolbar", because the third variant's restoring tap had not landed and
    /// the app opened in the schematic it had been left in. A suite whose
    /// first three runs pass and whose fourth fails on state left by the
    /// third is worse than one that never worked.
    ///
    /// THE LAST TAP IS STILL THE CLEANUP, for the same `@AppStorage` reason:
    /// the owner's simulator should open locations the way it did before.
    private func captureSchematicMap(_ app: XCUIApplication) {
        // Three modes, so at most two taps reach the schematic from any of
        // them; the third iteration exists only so the loop cannot end one
        // short of a mode it has not seen.
        for _ in 0..<mapModeDestinations.count {
            if app.navigationBars.buttons[schematicIsOn].exists { break }
            guard let next = mapModeDestinations
                .map({ app.navigationBars.buttons[$0] })
                .first(where: { $0.exists })
            else {
                XCTFail("""
                No map-mode button in the toolbar. Expected one labelled with the mode \
                it switches TO — «Опростена», «Схема» or «Точни очертания», from \
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

        guard app.navigationBars.buttons[schematicIsOn].exists else {
            XCTFail("cycled through every map mode without reaching the schematic")
            return
        }

        // Shorter than the 6s above: the parcels are already decoded by now,
        // and the schematic draws from the same values with no tiles to fetch.
        Thread.sleep(forTimeInterval: 3)
        capture("04-parcel-map-schematic", app: app)

        app.navigationBars.buttons[schematicIsOn].tap()
    }

    /// The three labels `ParcelMapMode.label` can put on the toolbar button.
    /// Spelled out here rather than imported: a UI test target runs in its own
    /// process and cannot link the app, so these strings are a copy and will
    /// go stale if the labels change. The `XCTFail` above says so by name.
    private let mapModeDestinations = ["Опростена", "Схема", "Точни очертания"]

    /// The button offers «Точни очертания» exactly when the schematic is what
    /// is on screen.
    private var schematicIsOn: String { "Точни очертания" }


    // MARK: - reaching the screens that are not tabs

    /// THE MENU HOLDS «ИЗХОД», so nothing here may tap by index.
    ///
    /// `AppMenuButton` lists the overflow surfaces, then Админ, then Профил
    /// and a destructive «Изход» that asks once and then calls
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

    /// «Нов запис», the most-used of the app's ten `Form`s (#156), opened
    /// and CANCELLED — «Създай» stays untouched, and is disabled on an empty
    /// title anyway.
    private func captureNewEntryForm(_ app: XCUIApplication) {
        let open = app.buttons["Нов запис"]
        guard open.waitForExistence(timeout: 5) else {
            XCTFail("no «Нов запис» on Дневник")
            return
        }
        open.tap()
        let cancel = app.buttons["Отказ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "«Нов запис» did not present its form")
        Thread.sleep(forTimeInterval: 1)
        capture("17-new-entry", app: app)
        cancel.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10),
                      "«Отказ» did not close «Нов запис»")
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

    /// «Съобщения» → the inbox → `thr_synthetic_1`.
    private func captureInboxAndConversation(_ app: XCUIApplication) {
        // A segment «Съобщения (2)» when four fit, a chip «Съобщения» (count
        // in its VALUE) when they do not or at an accessibility size —
        // `ExchangeSectionPicker`. `labelled` answers both.
        let section = labelled("Съобщения", in: app.buttons)
        XCTAssertTrue(section.waitForExistence(timeout: 10),
                      "no «Съобщения» segment or chip on Борса")
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
    /// not tap here: since P2.8 it opens Профил, and `captureProfile` reaches
    /// that page from the menu, which is the route every role has.
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

    /// Профил from the menu (agri-saas#1193 P2.8): the shared account card and
    /// the «Изход» row.
    ///
    /// ── «Изход» is FOUND, never tapped ──
    ///
    /// Its existence is asserted so the capture is known to show it; the tap
    /// would ask the confirmation, and the confirmation's answer clears the
    /// Keychain on a simulator that may be the owner's. `tapMenuRow` refuses
    /// the label outright, and nothing here calls `.tap()` on the row.
    ///
    /// The card is the same `AccountCard` Админ draws, so the same sentence is
    /// asserted: one VoiceOver stop, on the fixture account.
    private func captureProfile(_ app: XCUIApplication) {
        XCTAssertTrue(openMenu(app), "no «Меню» button on the root for Профил")
        XCTAssertTrue(tapMenuRow("Профил", in: app), "«Профил» is not in the menu")
        XCTAssertTrue(app.navigationBars["Профил"].waitForExistence(timeout: 20),
                      "Профил did not present a sheet")

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@",
                                  "Вписан като Иван Фикстуров, owner@example.invalid"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no account card on Профил")
        XCTAssertTrue(app.buttons["Изход"].waitForExistence(timeout: 5), "no «Изход» on Профил")
        Thread.sleep(forTimeInterval: 2)
        capture("16-profile", app: app)
        dismissSheet(app, named: "Профил")
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
        if app.buttons["Вход"].waitForExistence(timeout: 3) {
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
