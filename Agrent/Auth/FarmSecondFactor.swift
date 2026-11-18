import SwiftUI

/// A farm's second factor, presented in the app (#689).
///
/// ## Why this exists
///
/// Since agri-saas #3221 a native session is held PER FARM: a farm whose MFA
/// policy obliges a factor that was not presented in this session answers
/// `403 MFA_REQUIRED` on its `/api/t/{slug}/**` routes. Signing in again
/// through the browser sheet clears the farm that owes the factor, but an
/// Apple-only person has no browser sign-in, and the Apple ticket collects a
/// code for ONE farm — so a second farm stayed held, with no way through.
///
/// The server already accepts the code in-session:
/// `POST /api/t/{slug}/security/mfa/challenge/verify` resolves the session
/// from the bearer, checks the code against THE FARM IN THE URL (#3186), and
/// stamps that enrolment, which releases the farm on the next request. So the
/// app asks for the code where the refusal happens, for that farm, and the
/// open farm's screens are rebuilt when it is accepted.
///
/// `MFA_ENROLLMENT_REQUIRED` is not handled here: with no authenticator
/// enrolled there is no code to ask for, and that stays a message pointing at
/// the web's setup page.
enum FarmSecondFactorAPI {
    /// The open farm's verify route — the one farm this prompt is ever for.
    static func verifyPath(in farm: String?) -> String {
        FarmPath.root(for: farm) + "/security/mfa/challenge/verify"
    }

    /// `200 { success: true }` — accepted; `200 { success: false, remaining }`
    /// — a wrong code, with the attempts left before the rate limit. A `429`
    /// (too many attempts) arrives as an `APIError`, like any other refusal.
    struct Answer: Decodable, Sendable, Equatable {
        let success: Bool
        let remaining: Int?
    }

    /// NOT FIRED from tests, CI or A11yShots: it spends one of the person's
    /// rate-limited attempts against a real authenticator.
    static func verify(_ code: String, in farm: String) async throws -> Answer {
        let data = try await APIClient.shared.postReturningData(
            verifyPath(in: farm), body: ["code": code], idempotencyKey: nil)
        return try await APIClient.shared.decode(data, as: Answer.self)
    }
}

/// Which farm owes a code, and the prompt's state. One per app.
@MainActor
@Observable
final class FarmSecondFactor {
    static let shared = FarmSecondFactor()

    /// The farm the prompt is open for, as an `Identifiable` so a sheet can
    /// present it.
    struct Owed: Identifiable, Equatable, Sendable {
        let slug: String
        var id: String { slug }
    }

    /// The farm whose code is being asked for; nil while nothing is owed.
    var owed: Owed?
    private(set) var submitting = false
    private(set) var error: String?
    /// Bumped each time a code is refused, so the field can empty itself.
    private(set) var refusals = 0
    /// Bumped each time a farm is released: `FarmGate` keys the open farm's
    /// tabs on it, so every screen that was refused loads again.
    private(set) var releases = 0

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: APIClient.farmSecondFactorNotification, object: nil, queue: .main
        ) { [weak self] note in
            let slug = note.userInfo?["farm"] as? String
            MainActor.assumeIsolated { self?.refused(by: slug) }
        }
    }

    /// A route answered `MFA_REQUIRED`. Asked only for the OPEN farm: a
    /// background request to another of the person's farms (a push
    /// registration at launch) must not open a prompt for a farm they are
    /// not looking at, every time the app starts.
    func refused(by farm: String?, open: String? = FarmPath.openSlug) {
        guard let farm, !farm.isEmpty, farm == open, owed == nil else { return }
        error = nil
        owed = Owed(slug: farm)
    }

    /// «Не сега»: the prompt closes, and the next refusal opens it again.
    func dismiss() {
        guard !submitting else { return }
        owed = nil
        error = nil
    }

    func submit(_ code: String,
                verify: @Sendable (String, String) async throws -> FarmSecondFactorAPI.Answer
                    = FarmSecondFactorAPI.verify(_:in:)) async {
        guard let farm = owed?.slug, code.count == 6, !submitting else { return }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            let answer = try await verify(code, farm)
            // The prompt may have been closed, or the session ended, while the
            // code was out: its answer is then nobody's.
            guard owed?.slug == farm else { return }
            if answer.success {
                owed = nil
                releases += 1
                Self.announce(Words.released)
            } else {
                error = answer.remaining.map(AppleSignIn.Text.wrongCode(attemptsLeft:))
                    ?? AppleSignIn.Text.wrongCodeAgain
                refusals += 1
            }
        } catch {
            guard owed?.slug == farm else { return }
            self.error = UserMessage.text(for: error)
        }
    }

    /// Back to how a fresh launch finds it (`SessionReset`).
    func reset() {
        owed = nil
        submitting = false
        error = nil
        refusals = 0
    }

    private static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    enum Words {
        static let title = "Код за стопанството"
        static let explanation = "Това стопанство изисква двуфакторно потвърждение. Въведете шестцифрения "
            + "код от приложението си за кодове."
        static let notNow = "Не сега"
        static let released = "Кодът е приет. Стопанството е отключено."
    }
}

/// The code entry, as a sheet over the open farm.
struct FarmSecondFactorView: View {
    @State private var prompt = FarmSecondFactor.shared
    @State private var code = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Words = FarmSecondFactor.Words
    private typealias Shared = AppleSignIn.Text

    var body: some View {
        ScrollableState {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Words.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Words.explanation)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)

                TextField(Shared.codeField, text: $code, prompt: .fieldPrompt(Shared.codePrompt))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit {
                        if code.count == 6 { Task { await prompt.submit(code) } }
                    }
                    .accessibilityLabel(Shared.codeField)
                    .onChange(of: code) { _, typed in
                        let digits = AppleSignIn.digits(typed)
                        if digits != typed { code = digits }
                    }

                if let error = prompt.error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await prompt.submit(code) }
                    } label: {
                        if prompt.submitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(Shared.checking)
                        } else {
                            Text(Shared.confirm)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .prominentButton()
                    .disabled(code.count != 6 || prompt.submitting)
                    .accessibilityInputLabels(A11y.spokenNames(Shared.confirm, "Confirm"))

                    Button {
                        prompt.dismiss()
                    } label: {
                        Text(Words.notNow).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(prompt.submitting)
                    .accessibilityInputLabels(A11y.spokenNames(Words.notNow, "Not now"))
                }
                .controlSize(.large)
            }
            .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 24)
            .padding()
        }
        .onAppear { fieldFocused = true }
        // Closed only by its buttons: a swipe down mid-check would leave the
        // answer arriving for a prompt nobody is looking at.
        .interactiveDismissDisabled(prompt.submitting)
        .onChange(of: prompt.error) { _, error in
            guard let error else { return }
            var line = AttributedString(error)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
        .onChange(of: prompt.refusals) {
            code = ""
            fieldFocused = true
        }
    }
}
