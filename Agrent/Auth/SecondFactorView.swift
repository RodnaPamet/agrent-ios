import SwiftUI

/// The authenticator code, after Sign in with Apple at a farm that requires a
/// second factor (agri-saas #1649, agrent-ios#274).
///
/// Apple only: Google and Microsoft ask for the code inside their sign-in
/// sheet, on the web's own page, before the app is given anything. Apple's
/// sign-in has no sheet, so the server hands back a ticket instead of a pair
/// and this screen redeems it — six digits from whatever authenticator the
/// person set up, typed or filled in by iOS (`.oneTimeCode`).
///
/// No countdown. The ticket lasts five minutes, which is time to switch to
/// the authenticator and back; a clock ticking under the field would only
/// hurry someone reading a code. When it does run out, the sign-in screen
/// says so (`AuthClient.submitCode`).
struct SecondFactorView: View {
    @Environment(AuthClient.self) private var auth
    @State private var code = ""
    @FocusState private var fieldFocused: Bool

    private typealias Words = AppleSignIn.Text

    var body: some View {
        // Scrollable when it has to be, as the sign-in screen: at AX5 the
        // explanation alone runs past half the screen.
        ScrollableState {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Words.codeTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Words.codeExplanation)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)

                TextField(Words.codeField, text: $code, prompt: .fieldPrompt(Words.codePrompt))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .accessibilityLabel(Words.codeField)
                    .onChange(of: code) { _, typed in
                        // Digits only, six at most — a pasted «123 456» keeps
                        // its digits, and nothing else reaches the server.
                        let digits = AppleSignIn.digits(typed)
                        if digits != typed { code = digits }
                    }

                if let error = auth.codeError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await auth.submitCode(code) }
                    } label: {
                        if auth.submittingCode {
                            ProgressView().accessibilityLabel(Words.checking)
                        } else {
                            Text(Words.confirm)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .prominentButton()
                    .disabled(code.count != 6 || auth.submittingCode)
                    .accessibilityInputLabels(A11y.spokenNames(Words.confirm, "Confirm"))

                    // Not while the code is on its way: its answer would sign
                    // in a person who had already chosen to leave.
                    Button {
                        auth.cancelCode()
                    } label: {
                        Text("Отказ").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(auth.submittingCode)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding()
        }
        .onAppear { fieldFocused = true }
        // A refusal is said, not only shown, and the field is emptied for the
        // next code — the one refused is no use again.
        .onChange(of: auth.codeError) { _, error in
            guard let error else { return }
            code = ""
            AccessibilityNotification.Announcement(error).post()
        }
    }
}
