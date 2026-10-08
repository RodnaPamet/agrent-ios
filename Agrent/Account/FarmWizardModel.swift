import Foundation
import Observation

/// Creating a farm (agrent-ios#179): the web's `/start` steps 3–6, for a
/// person who is already signed in — signing in with Google made the account.
///
///     type  → «Какво е стопанството Ви?»   company, or физическо лице
///     eik   → the register's verdict, live  (company only)
///     name  → prefilled from the register    POST /api/me/farms
///     done  → «Стопанството Ви е онлайн»    open it
///
/// ── What never happens ──
///
/// - An ЕИК that is not VALID never goes on. An ЕГН typed by mistake stops
///   the step dead rather than warning and allowing, as on the web: it is
///   a personal identity number, and it would reach the ДНЕВНИК PDF and the
///   БАБХ register export.
/// - `pending_review` is never shown as acceptance — see
///   `FarmsAPI.IdentityVerification`.
/// - Nothing derives the farm's slug from its name; it comes back from the
///   create.
@Observable
@MainActor
final class FarmWizardModel {
    /// Codable for `FarmWizardDraft`.
    enum Step: String, Equatable, Codable { case type, eik, name, done }
    enum Kind: String, Equatable, Codable { case company, individual }

    /// What is known about the ЕИК typed so far.
    enum EikState: Equatable {
        /// Fewer than nine characters: nothing to ask about yet.
        case idle
        case checking
        case valid(registryName: String?)
        case invalid
        case looksLikeEgn
        /// The check itself could not be made — offline, say.
        case failed(String)
    }

    private(set) var step: Step = .type
    private(set) var kind: Kind?
    private(set) var eik = ""
    private(set) var eikState: EikState = .idle
    var name = "" {
        didSet { persist() }
    }
    private(set) var busy = false
    private(set) var error: String?
    /// The last refusal was the terms gate: the farmer can do something about
    /// it — accept them on the web — and the screen offers the way there.
    private(set) var needsTerms = false
    private(set) var created: FarmsAPI.Created?

    /// The steps THIS person walks — the физическо лице path has no ЕИК, so
    /// it is three, and the counter says so rather than "2 of 4" then done.
    var walk: [Step] { kind == .individual ? [.type, .name, .done] : [.type, .eik, .name, .done] }

    var position: (current: Int, total: Int) {
        ((walk.firstIndex(of: step) ?? 0) + 1, walk.count)
    }

    var mayConfirmEik: Bool {
        if case .valid = eikState { return true }
        return false
    }

    var maySubmit: Bool { !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ObservationIgnored private let check: @MainActor (String) async throws -> FarmsAPI.EikVerdict
    @ObservationIgnored private let send: @MainActor (FarmsAPI.CreateFarm) async throws -> FarmsAPI.Created
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var checking: Task<Void, Never>?
    /// The name the register last put in the field, so a later verdict may
    /// replace it — but never a name the farmer typed themselves.
    @ObservationIgnored private var prefilled: String?

    /// The ЕИК the register last called VALID, trimmed — the only one a draft
    /// may keep. Kept apart from `eikState` because a resume asks the
    /// register again, and a draft written while that answer is on its way
    /// must not lose the ЕИК it already had.
    @ObservationIgnored private(set) var verifiedEik: String?

    /// Where this wizard keeps its draft, and whose it is (#197). Nil for
    /// either keeps nothing: the default, so a test never touches the
    /// phone's real storage; `FarmWizardView` passes both.
    @ObservationIgnored private let drafts: FarmWizardDrafts?
    @ObservationIgnored private let owner: String?

    init(
        check: @escaping @MainActor (String) async throws -> FarmsAPI.EikVerdict = { try await FarmsAPI.checkEik($0) },
        send: @escaping @MainActor (FarmsAPI.CreateFarm) async throws -> FarmsAPI.Created = { try await FarmsAPI.create($0) },
        debounce: Duration = .milliseconds(400),
        drafts: FarmWizardDrafts? = nil,
        owner: String? = nil
    ) {
        self.check = check
        self.send = send
        self.debounce = debounce
        self.drafts = drafts
        self.owner = owner
        if let owner, let draft = drafts?.draft(for: owner) { resume(draft) }
    }

    // MARK: - Resuming (#197)

    /// Where the person left it. A kept ЕИК is asked of the register AGAIN —
    /// a verdict from before the app was killed is not one to act on — and
    /// until it answers, it is still the verified one (`verifiedEik`).
    ///
    /// The STEP FIRST: setting the ЕИК and the name each write the draft
    /// back, and a draft written with the first step would bring the person
    /// back to the start on the next kill.
    private func resume(_ draft: FarmWizardDraft) {
        step = draft.step
        kind = draft.kind
        prefilled = draft.prefilled
        if !draft.eik.isEmpty {
            verifiedEik = draft.eik
            setEik(draft.eik)
        }
        name = draft.name
    }

    /// The draft as things stand: written at every move, cleared once the
    /// farm exists — and never written for a wizard nobody has started.
    private func persist() {
        guard let drafts, let owner else { return }
        if step == .done || (kind == nil && name.isEmpty) {
            drafts.clear()
            return
        }
        let typed = eik.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts.save(FarmWizardDraft(
            owner: owner, step: step, kind: kind,
            eik: verifiedEik == typed ? typed : "",
            name: name, prefilled: prefilled))
    }

    /// «Отказ»: the person chose not to make this farm. Nothing to resume.
    func discard() {
        drafts?.clear()
    }

    // MARK: - Moving

    func choose(_ kind: Kind) {
        self.kind = kind
        error = nil
        step = kind == .company ? .eik : .name
        persist()
    }

    /// One step back along this person's walk. Not from `done`: the farm
    /// exists by then, and "back" would offer to create it again.
    func back() {
        guard step != .done, let index = walk.firstIndex(of: step), index > 0 else { return }
        error = nil
        step = walk[index - 1]
        persist()
    }

    /// «Да, това е моето стопанство» — only on a VALID verdict.
    func confirmEik() {
        guard case .valid(let registryName) = eikState else { return }
        if let registryName, name.isEmpty || name == prefilled {
            name = registryName
            prefilled = registryName
        }
        error = nil
        step = .name
        persist()
    }

    // MARK: - The ЕИК, live

    /// Every keystroke: the previous check is cancelled, and a pause in the
    /// typing asks the register — from nine characters, as the web does, so
    /// a ten-digit ЕГН is caught too. Trimmed, like the web; the server reads
    /// surrounding spaces itself.
    func setEik(_ text: String) {
        eik = text
        checking?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { persist() }
        guard trimmed.count >= 9 else {
            eikState = .idle
            return
        }
        eikState = .checking
        // Through `self`, a main-actor class, rather than capturing the
        // closures: a `Task` body is `@Sendable`, and they are not.
        checking = Task {
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let verdict = try await self.check(trimmed)
                guard !Task.isCancelled else { return }
                eikState = verdict.looksLikeEgn ? .looksLikeEgn
                    : verdict.valid ? .valid(registryName: verdict.registryName?.recorded)
                    : .invalid
                // Only VALID is kept; a refusal or an ЕГН unkeeps it.
                verifiedEik = verdict.valid && !verdict.looksLikeEgn ? trimmed : nil
                self.persist()
            } catch {
                guard !Task.isCancelled else { return }
                eikState = .failed(UserMessage.text(for: error))
            }
        }
    }

    // MARK: - Creating

    /// The request: the name, and the ЕИК only on the company path — absent,
    /// not null, for «Земеделски стопанин».
    var request: FarmsAPI.CreateFarm {
        FarmsAPI.CreateFarm(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            eik: kind == .company ? eik.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    /// Creates a REAL farm. One at a time: `busy` holds the button off, so a
    /// second tap cannot make a second farm.
    func submit() async {
        guard maySubmit else { return }
        busy = true
        error = nil
        needsTerms = false
        defer { busy = false }
        do {
            created = try await send(request)
            step = .done
            persist()
        } catch {
            self.error = UserMessage.text(for: error)
            needsTerms = Self.isTermsRefusal(error)
        }
    }

    /// The terms gate's 403, coded by the server since agri-saas #1405.
    static func isTermsRefusal(_ error: Error) -> Bool {
        guard case APIClient.APIError.http(_, let code, _, _, _) = error else { return false }
        return code == "TERMS_ACCEPTANCE_REQUIRED"
    }

    /// The farm to open once it exists. Its creator is its OWNER — the spec's
    /// own words for the POST — so it opens with that role rather than the
    /// OLDEST membership's, before any list has been read.
    var farm: Farm? {
        created.map { Farm(slug: $0.farm.slug, name: $0.farm.name, role: "OWNER") }
    }
}
