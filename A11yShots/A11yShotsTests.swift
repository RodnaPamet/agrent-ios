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
