import XCTest
@testable import Agrent

/// Профил for every role (agri-saas#1193 P2.8), reached from Админ's top row
/// and nowhere else since the owner took «Профил» and «Изход» out of the menu
/// (2026-10-07); the shared card; and Изход behind one confirmation.
///
/// The wiring is read from the source, as `MenuSheetCloseTests` reads it:
/// hosting the menu, a sheet and `AuthClient` to look for a row would test the
/// Keychain more than the wiring. Each probe has a positive control, so a
/// moved file fails rather than passes.
final class ProfileTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every Swift file under `Agrent/`, with its path relative to the repo.
    private func appSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Agrent")
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return try files.map { url in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""),
             try String(contentsOf: url, encoding: .utf8))
        }
    }

    // MARK: - The menu

    /// The menu keeps «Админ» and holds neither «Профил» nor «Изход» (owner,
    /// 2026-10-07): both are reached through Админ now.
    func testTheMenuLeavesProfileAndIzhodToAdmin() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        XCTAssertTrue(menu.contains("struct AppMenuButton"), "positive control: the menu moved")
        // Админ stays — and without it nothing reaches Профил or Изход.
        XCTAssertTrue(menu.contains(#"Label("Админ", systemImage: "person.2")"#),
                      "«Админ» left the menu, and with it the only way to Профил and Изход")
        XCTAssertTrue(menu.contains(".sheet(isPresented: $showingAdmin) { AdminView() }"))
        for row in [#"Label("Профил""#, #"Label("Изход""#, "ProfileView()", ".signOutConfirmation("] {
            XCTAssertFalse(menu.contains(row), "the menu has \(row) again")
        }
    }

    /// Админ has a section of its own (owner, 2026-10-07), where the account
    /// rows used to be — not a row among the farm's screens.
    func testAdminHasItsOwnMenuSection() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        let screens = try XCTUnwrap(menu.range(of: #"Section(titled: farms.activeFarm.map { $0.name ?? $0.slug } ?? "") {"#),
                                    "positive control: the screens' section moved")
        let admin = try XCTUnwrap(menu.range(of: #"Label("Админ", systemImage: "person.2")"#),
                                  "positive control: «Админ» left the menu")
        XCTAssertLessThan(screens.lowerBound, admin.lowerBound, "«Админ» is no longer last")
        // Between the two, the screens' section closes and another opens.
        let between = String(menu[screens.upperBound..<admin.lowerBound])
        XCTAssertTrue(between.contains("ForEach(tabs.overflow)"), "positive control: no screens before Админ")
        XCTAssertTrue(between.contains("\n            Section {"),
                      "«Админ» is a row in the screens' section again")
    }

    // MARK: - Админ, the one way in

    /// Профил is opened from Админ's account row — and that row is drawn
    /// OUTSIDE the access switch, so a reader whom Админ refuses still has it,
    /// and with it the app's only Изход.
    ///
    /// The one other opener is `FarmGate`'s farm-less states (#179): with no
    /// farm open there are no tabs, no menu and so no Админ, and a person who
    /// belongs to no farm must still be able to reach Изход.
    func testAdminOpensProfileInEveryState() throws {
        let openers = try appSources().filter { $0.1.contains("ProfileView()") }
        XCTAssertEqual(Set(openers.map(\.0)), ["Agrent/Admin/AdminView.swift", "Agrent/Core/FarmGate.swift"],
                       "Профил is opened from somewhere other than Админ and the farm gate")

        let admin = try source("Agrent/Admin/AdminView.swift")
        let row = try XCTUnwrap(admin.range(of: "Section { accountRow }"),
                                "positive control: Админ draws no account row")
        let gate = try XCTUnwrap(admin.range(of: "switch store.access"),
                                 "positive control: Админ no longer switches on access")
        XCTAssertLessThan(row.lowerBound, gate.lowerBound,
                          "the account row is inside the access switch — a reader loses Изход")

        // Not waiting for `/me` either: no name yet still means a row.
        let decl = try XCTUnwrap(admin.range(of: "private var accountRow: some View {"))
        let end = try XCTUnwrap(admin.range(of: "private var forbiddenNotice", range: decl.upperBound..<admin.endIndex),
                                "positive control: the notice no longer follows the row")
        let body = String(admin[decl.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("ProfileView()"), "the account row opens something else")
        XCTAssertTrue(body.contains("AccountCard(user: user)"), "the row's label is not the card")
        XCTAssertTrue(body.contains(#"Label("Профил", systemImage: "person.crop.circle")"#),
                      "no row until /me answers — an offline launch has no Изход")
        XCTAssertFalse(body.contains("if let user = me.user {\n            NavigationLink"),
                       "the whole row waits for /me again")
        XCTAssertTrue(body.contains(".accessibilityInputLabels(A11y.Spoken.profile"))
    }

    /// THE INVARIANT: `AuthClient.signOut()` is called from exactly one view,
    /// the confirmation. A new Изход that called it directly would skip the
    /// question the owner asked for.
    func testOnlyTheConfirmationSignsOut() throws {
        let callers = try appSources().filter { path, text in
            path != "Agrent/Auth/AuthClient.swift" && text.contains(".signOut()")
        }
        XCTAssertEqual(callers.map(\.0), ["Agrent/Account/SignOutConfirmation.swift"])
        let confirmation = try source("Agrent/Account/SignOutConfirmation.swift")
        XCTAssertTrue(confirmation.contains("struct SignOutConfirmation: ViewModifier"),
                      "positive control: SignOutConfirmation moved")
        XCTAssertTrue(confirmation.contains(#"Button("Изход", role: .destructive) { auth.signOut() }"#))
        XCTAssertEqual(confirmation.components(separatedBy: ".signOut()").count - 1, 1,
                       "the confirmation signs out in one place, its destructive answer")
        // Both of its answers can be said aloud.
        XCTAssertTrue(confirmation.contains(".accessibilityInputLabels(A11y.Spoken.signOut)"))
        XCTAssertTrue(confirmation.contains(".accessibilityInputLabels(A11y.Spoken.cancel)"))
    }

    // MARK: - The page and the card

    /// One card: Профил draws the same `AccountCard` Админ's row does (held by
    /// the test above), not a copy — and it holds the app's only Изход, which
    /// asks first and can be said aloud.
    func testProfileSharesTheCardAndHoldsIzhod() throws {
        let profile = try source("Agrent/Account/ProfileView.swift")
        XCTAssertTrue(profile.contains("struct ProfileView"), "positive control: ProfileView moved")
        XCTAssertTrue(profile.contains("AccountCard(user: user)"))
        XCTAssertTrue(profile.contains(#"Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")"#))
        XCTAssertTrue(profile.contains(".signOutConfirmation(isPresented: $confirmingSignOut)"))
        XCTAssertTrue(profile.contains(".accessibilityInputLabels(A11y.Spoken.signOut)"))
    }

    /// Профил reads `/me` and nothing tenant-scoped — so it works for a person
    /// in any farm, and the web's `/account` works with zero.
    func testTheProfilePageAsksForNothingTenantScoped() throws {
        let profile = try source("Agrent/Account/ProfileView.swift")
        XCTAssertTrue(profile.contains("CurrentUserStore.shared"), "positive control")
        for tenantScoped in ["FarmPath", "/api/t/", "APIClient"] {
            XCTAssertFalse(profile.contains(tenantScoped), "Профил reaches for \(tenantScoped)")
        }
    }

    // MARK: - Words

    func testTheConfirmationSaysWhatIzhodCosts() {
        let plain = SignOutConfirmation.message(unsent: false)
        XCTAssertEqual(plain, "За да продължите, ще трябва да влезете отново.")
        let withQueue = SignOutConfirmation.message(unsent: true)
        XCTAssertTrue(withQueue.hasPrefix(plain))
        XCTAssertTrue(withQueue.contains("Неизпратените записи остават на телефона"))
        for text in [plain, withQueue, ProfileView.unavailable] {
            XCTAssertTrue(text.hasSuffix("."), "not a full sentence: \(text)")
            XCTAssertNil(text.range(of: "[A-Za-z]", options: .regularExpression),
                         "Latin letters in Bulgarian UI text: \(text)")
        }
        XCTAssertTrue(SignOutConfirmation.title.hasSuffix("?"))
    }

    func testProfileAndIzhodAreSayable() {
        XCTAssertEqual(A11y.Spoken.profile, ["Профил", "Profile"])
        XCTAssertEqual(A11y.Spoken.signOut, ["Изход", "Sign out"])
    }
}
