import Foundation

/// How far creating a farm got, kept on this phone so the wizard picks up
/// where the person left it if the app is killed (agrent-ios#197, P4.8:
/// "onboarding resumes after the app is killed").
///
/// ── What it keeps, and what it never does ──
///
/// The step, the kind of farm, the name, and the ЕИК — but only an ЕИК the
/// register called VALID (`FarmWizardModel.verifiedEik`). Never one half
/// typed, never one the register refused, and never one that looked like an
/// ЕГН: that is a personal identity number, and this wizard stops it dead
/// rather than carry it anywhere — the phone's storage included.
///
/// Never `done`: once the farm exists there is nothing to resume, and a
/// draft that survived it would offer to create it again.
struct FarmWizardDraft: Codable, Equatable {
    /// Whose it is. A draft resumes only for the person who started it.
    let owner: String
    var step: FarmWizardModel.Step
    var kind: FarmWizardModel.Kind?
    var eik: String
    var name: String
    /// The register's name last put in the field, so the rule that it never
    /// overwrites the person's own typing holds after a resume too.
    var prefilled: String?
}

/// Where the draft lives: ONE per phone, for whoever is signed in.
///
/// `UserDefaults`, not the Keychain: nothing in it is secret — a farm's
/// name and a register's public ЕИК. One key, not one per person, so a
/// sign-out can clear it without knowing whose it was (`SessionReset`): a
/// half-made farm's name does not stay on a shared phone after its person
/// has gone. Another account never resumes it — `owner` is checked — and
/// overwrites it the moment it starts its own.
struct FarmWizardDrafts {
    let defaults: UserDefaults

    static let key = "farmWizard.draft.v1"

    func draft(for owner: String) -> FarmWizardDraft? {
        guard let data = defaults.data(forKey: Self.key),
              let draft = try? JSONDecoder().decode(FarmWizardDraft.self, from: data),
              draft.owner == owner, draft.step != .done
        else { return nil }
        return draft
    }

    func save(_ draft: FarmWizardDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
