import SwiftUI

/// The terms screen a brand-new account meets before anything else
/// (agrent-ios#193) — see `TermsAPI` for why it exists and why the version
/// shown is the version sent.
///
/// Before it, nothing of a farm or a person can be read: the server's terms
/// gate answers 403 to all of it. So this is the whole app until it is done,
/// with «Изход» as the other way out — through `SignOutConfirmation`, the one
/// question any Изход asks.
struct TermsAcceptanceView: View {
    @Environment(AuthClient.self) private var auth
    @State private var store = TermsStore()
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section { Text(TermsText.lead) }.pageRow()

                switch store.state {
                case .loading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Зареждане на условията")
                    }
                    .pageRow()
                case .failed(let message):
                    Section {
                        Button("Опитай пак") { Task { await store.load() } }
                    } footer: {
                        SectionFooter(message)
                    }
                    .pageRow()
                case .ready(let terms):
                    Section {
                        if let page = terms.page {
                            Link(destination: page) {
                                Label(TermsText.read, systemImage: "doc.text")
                            }
                        }
                        Button {
                            Task { if await store.accept() { await auth.termsAccepted() } }
                        } label: {
                            if store.accepting {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label(TermsText.accept, systemImage: "checkmark.seal")
                            }
                        }
                        .disabled(store.accepting)
                        .accessibilityInputLabels(A11y.spokenNames(TermsText.accept, "Accept"))
                    } footer: {
                        SectionFooter {
                            if let failure = store.acceptFailure { Text(failure) }
                        }
                    }
                    .pageRow()
                }

                Section {
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Label("Изход", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityInputLabels(A11y.Spoken.signOut)
                    .signOutConfirmation(isPresented: $confirmingSignOut)
                }
                .pageRow()
            }
            .pageBackground()
            .inlineTitle(TermsText.title)
            .task { await store.load() }
        }
    }
}
