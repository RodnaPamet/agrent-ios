import XCTest
@testable import Agrent

/// Профил for every role (agri-saas#1193 P2.8): the menu row, the Админ card
/// as a link to it, the shared card, and Изход behind one confirmation.
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

    /// «Профил» is in the menu for everyone: in its own section, NOT under an
    /// `if` on the role — the owner's "every role" is the whole point.
    func testTheMenuOffersProfileToEveryRole() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        XCTAssertTrue(menu.contains("struct AppMenuButton"), "positive control: the menu moved")
        guard let row = menu.range(of: #"Label("Профил", systemImage: "person.crop.circle")"#) else {
            return XCTFail("no «Профил» row in the menu")
        }
        // The stretch of the menu body before the row holds no role check.
        let before = String(menu[..<row.lowerBound])
        guard let body = before.range(of: "var body: some View", options: .backwards) else {
            return XCTFail("positive control: the menu has no body before the row")
        }
        let lead = String(before[body.upperBound...])
        for gate in ["isOperator", "mayWrite", ".role", "isAdmin"] {
            XCTAssertFalse(lead.contains(gate), "the «Профил» row sits behind \(gate)")
        }
        XCTAssertTrue(menu.contains(".accessibilityInputLabels(A11y.Spoken.profile)"))
        // Presented as the menu's own sheet, flagged so the page draws «Затвори».
        XCTAssertTrue(menu.contains("NavigationStack { ProfileView() }"))
        XCTAssertTrue(menu.contains(".environment(\\.presentedFromMenu, true)"))
    }

    /// The menu's Изход ASKS: it sets the flag, and the one confirmation does
    /// the signing out.
    func testTheMenuIzhodAsksFirst() throws {
        let menu = try source("Agrent/Design/AppMenu.swift")
        XCTAssertTrue(menu.contains(#"Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")"#),
                      "positive control: the menu's Изход row moved")
        XCTAssertTrue(menu.contains("confirmingSignOut = true"))
        XCTAssertTrue(menu.contains(".signOutConfirmation(isPresented: $confirmingSignOut)"))
        XCTAssertTrue(menu.contains(".accessibilityInputLabels(A11y.Spoken.signOut)"))
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

    /// One card: Админ links its card to Профил, and Профил draws the same
    /// `AccountCard` rather than a copy of it.
    func testAdminAndProfileShareOneCard() throws {
        let admin = try source("Agrent/Admin/AdminView.swift")
        XCTAssertTrue(admin.contains("struct AdminView"), "positive control: AdminView moved")
        let link = try XCTUnwrap(admin.range(of: "NavigationLink {\n                            ProfileView()"),
                                 "Админ's card does not link to Профил")
        let tail = String(admin[link.upperBound...].prefix(200))
        XCTAssertTrue(tail.contains("AccountCard(user: user)"), "the link's label is not the card")

        let profile = try source("Agrent/Account/ProfileView.swift")
        XCTAssertTrue(profile.contains("AccountCard(user: user)"))
        XCTAssertTrue(profile.contains(".closeWhenPresentedFromMenu()"),
                      "Профил from the menu would have no «Затвори»")
        XCTAssertTrue(profile.contains(".signOutConfirmation(isPresented: $confirmingSignOut)"))
        XCTAssertTrue(profile.contains(".accessibilityInputLabels(A11y.Spoken.signOut)"))
    }

    /// Профил reads `/me` and nothing tenant-scoped — so it works for a person
    /// in any farm, and the web's `/account` works with zero.
    func testTheProfilePageAsksForNothingTenantScoped() throws {
        let profile = try source("Agrent/Account/ProfileView.swift")
        XCTAssertTrue(profile.contains("CurrentUserStore.shared"), "positive control")
        for tenantScoped in ["Config.tenantSlug", "/api/t/", "APIClient"] {
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
