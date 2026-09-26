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
/// ── Why this reaches anything at all, and the day it stops ──
///
/// The app opens on `SignInView` unless `TokenStore.load()` finds tokens in
/// the Keychain (`AgrentApp.swift`), and there is NO test seam: a grep for
/// `ProcessInfo`, launch arguments or a stubbed `AuthClient` across
/// `Agrent/` and `Tests/` returns nothing. So this suite does not sign in.
/// It relies on the simulator it runs against ALREADY holding a valid token,
/// which the one on this machine does — verified 2026-09-26 by the app
/// writing six fresh files into `Library/Caches/ResponseCache` within seconds
/// of launch, i.e. by authenticated fetches against production succeeding.
///
/// That makes this reproducible on this machine and NOT on CI, where the
/// simulator is new every run. `assertSignedIn` fails with that sentence
/// rather than photographing a sign-in screen and calling it coverage.
///
/// ── Read-only, deliberately ──
///
/// Everything here taps tab bar buttons and list rows, which are GETs against
/// the owner's production tenant. Nothing taps «Нов запис», a save, a send or
/// anything else that writes, and nothing should be added that does: this
/// runs against the real farm's real data, not a fixture.
///
/// The screenshots therefore contain real locations, real parcel names and
/// real boundaries. `scripts/a11y-shots.sh` writes them outside the
/// repository for that reason. They must not be committed — this repo is
/// public, and `Tests/Fixtures/README.md` records that publishing the real
/// geometry is the owner's decision and the default is no.
@MainActor
final class A11yShotsTests: XCTestCase {

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
        app.launch()

        assertSignedIn(app)

        // Дневник, the launch screen. #97 asks whether a list row stacks at
        // AX sizes and whether the `·` between the values disappears with it;
        // this row is `JournalRow` → `AdaptiveRow` → `MetaRow`, the exact
        // shape PR #93 changed.
        capture("01-journal", app: app)

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

        // Задачи and Борса ARE in the default bar — but the bar is whatever the
        // server sent, so this asks the tab bar first and falls back to the
        // menu rather than assuming. A suite that assumes a tab exists reports
        // "no Задачи button" for a farm that simply arranged its bar
        // differently.
        captureTabOrMenu("08-tasks", label: "Задачи", app: app)
        captureTabOrMenu("09-exchange", label: "Борса", app: app)

        // Локации → a location's map: the one #97 calls "the one that matters
        // most", because Increase Contrast is what switches the near-solid
        // fill on and the label outline is the answer to it.
        XCTAssertTrue(app.tabBars.buttons["Локации"].waitForExistence(timeout: 10),
                      "no «Локации» button in the tab bar")
        app.tabBars.buttons["Локации"].tap()

        // 20 seconds because the list is a network read and `APIClient` gives
        // a request 15 of them before it fails (APIClient.swift, the
        // `timeoutIntervalForRequest = 15` note). A shorter wait here would
        // report "no locations" for what is actually a slow answer.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20),
                      "Локации showed no rows within 20s — signed in, but the list did not load")
        capture("02-locations", app: app)

        // WHICH LOCATION IS A CHOICE, and the default is the wrong one for the
        // item that matters. On this tenant row 0 is «Sample field» — three
        // parcels that project to one overlapping square — and row 1 is the
        // owner's own farm, whose four fields are what #93 measured the label
        // contrast against. Row 0 stays the default because it is the one row a
        // non-empty list is guaranteed to have; `ROW=1 scripts/a11y-shots.sh`
        // photographs the real farm instead.
        let rows = app.cells
        guard locationRow < rows.count else {
            XCTFail("Локации has \(rows.count) rows; A11Y_LOCATION_ROW=\(locationRow) is out of range")
            return
        }
        rows.element(boundBy: locationRow).tap()

        // There is no element to wait on inside either map — the satellite
        // modes are a MapKit view and the schematic is a `Canvas`, and both
        // are one opaque rectangle. The navigation bar's back button is the
        // closest thing to a signal that the push completed, and then the
        // parcels still have to arrive over the network.
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 20),
                      "the location did not push a screen")
        // A fixed wait, and it is a guess rather than a measurement: nothing
        // published by the map says "the parcels are drawn". If a capture
        // comes out empty this is the number to raise.
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
    /// `AppMenuButton` lists the overflow surfaces, then Админ, then a
    /// destructive «Изход» that calls `auth.signOut()` — which clears the
    /// Keychain. This suite runs against a simulator somebody has SIGNED IN ON,
    /// without the DEBUG seam, so a mis-tap there would destroy a real Google
    /// session and every subsequent capture would be of `SignInView`.
    ///
    /// Every lookup below is by exact label. There is no `element(boundBy:)`
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
        let row = app.buttons[label]
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap()
        return true
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
        let tab = app.tabBars.buttons[label]
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

    /// ТАБЛО HAS NO DISMISS BUTTON, which is why this is not just a tap.
    ///
    /// `DashboardView` has no «Затвори» and no `dismiss` of its own — the only
    /// `@Environment(\.dismiss)` in that file belongs to `DashboardBlockPicker`.
    /// So a sheet showing it can only be left by dragging it down. The other
    /// five all have «Затвори» in the leading slot.
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

    /// Админ, MASKED, and the swipe that #99 is about.
    ///
    /// ── The ЕГН is never revealed ──
    ///
    /// A member row carries a national identity number behind «Покажи».
    /// `AdminView` draws dots until that is tapped, so simply never tapping it
    /// means no identity number is written to a PNG — the row's layout,
    /// contrast and Dynamic Type are all still visible, which is what the audit
    /// changed. The owner chose this over skipping the screen or revealing it.
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

        // No assertion that the digits are absent. `x && false` would have
        // been one that cannot fail, which is the defect this repo has spent a
        // week removing — and there is nothing honest to assert here anyway:
        // the guarantee is that this method never taps «Покажи», which is a
        // property of the code above and not of the image below.
        capture("10-admin-masked", app: app)

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
        // The first cell on this screen is «Долна лента» under «Приложение»,
        // which has no swipe actions at all. Swiping it photographed an
        // untouched screen and looked like a successful capture; only opening
        // the image showed the swipe had answered a different question.
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
        // «Долна лента» alone fills most of an accessibility5 screen, so the
        // first member row starts off-screen. The swipe checks then failed the
        // test, `continueAfterFailure` is false, and the run produced ZERO
        // screenshots for the one text size the Dynamic Type items are about.
        // A check that cannot run taking the captures down with it is the worst
        // of both.
        //
        // So: scroll toward them first, and if they are still not reachable,
        // skip the swipe pair and say so. The #99 assertions run at the other
        // three sizes, and what AX5 is FOR is the layout capture above.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)

        let ownerRow = app.descendants(matching: .other)
            .matching(NSPredicate(format: "label CONTAINS %@", "Собственик"))
            .firstMatch
        guard ownerRow.waitForExistence(timeout: 10), ownerRow.isHittable else {
            // NOT silent. The variant's output is short two files and this says
            // why, so a reader comparing directories is not left guessing.
            print("SKIPPED the #99 swipe checks: no hittable «Собственик» row at this "
                  + "text size. Expected at the accessibility sizes; if it happens at "
                  + "the default size, access is refused or the row label changed.")
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

        dismissSheet(app, named: "Админ")
    }

    // MARK: - helpers

    /// Which row of Локации to open, from `A11Y_LOCATION_ROW`.
    ///
    /// `xcodebuild` passes an environment variable through to the test runner
    /// when it is prefixed `TEST_RUNNER_`, and strips the prefix on the way in
    /// — so `TEST_RUNNER_A11Y_LOCATION_ROW=1 xcodebuild test …` arrives here as
    /// `A11Y_LOCATION_ROW`. That is the only channel: the runner is a separate
    /// process, so a `-` launch argument would reach the app under test and not
    /// this code.
    ///
    /// An unparseable value falls back to 0 rather than failing, because the
    /// suite's job is screenshots and the row is a preference.
    private var locationRow: Int {
        ProcessInfo.processInfo.environment["A11Y_LOCATION_ROW"].flatMap(Int.init) ?? 0
    }

    /// Names the blocker in one sentence instead of letting the suite
    /// photograph `SignInView` three times and look green.
    private func assertSignedIn(_ app: XCUIApplication) {
        let signInButton = app.buttons["Вход"]
        // A short wait ON PURPOSE. `SignInView` is what the app shows while
        // it is NOT signed in, so its appearance is the thing being ruled
        // out; waiting 10 seconds for it would just slow every green run.
        if signInButton.waitForExistence(timeout: 3) {
            XCTFail("""
            The app is on SignInView, so nothing behind auth can be captured.

            This suite does not sign in and cannot: sign-in runs through \
            ASWebAuthenticationSession against Google, and the app has no test \
            seam — no launch argument, no stubbed AuthClient, no fixture-backed \
            client. It needs a simulator whose Keychain already holds a valid \
            token. Adding a seam is an app change with its own risk and is the \
            owner's call, not this suite's.
            """)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15),
                      "no tab bar appeared within 15s — the app is neither signed in nor on SignInView")
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
