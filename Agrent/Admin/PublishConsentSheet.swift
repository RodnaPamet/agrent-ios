import SwiftUI

/// The consent asked for by «Публикувай» when the farm hasn't agreed to the
/// text this build shows (`PublishingConsent`), then the publication.
///
/// ── Asked by the act it permits ──
///
/// As on the web, consent isn't a step to have done earlier: it's raised by
/// publishing, so the agreement is made at the moment it has an effect. The
/// button stays disabled until the switch is on, because the record says a
/// person was shown a text and agreed, and a stray tap mustn't make it.
///
/// ── Two calls, consent first ──
///
/// If the consent is recorded and publishing is then refused (no name, say),
/// the consent stands and the page stays private. That's the safe direction:
/// an agreement with nothing published is true, a published page with no
/// agreement would not be. The page behind the sheet is read again either
/// way, so it shows the recorded consent.
struct PublishConsentSheet: View {
    /// The farm agreed once, to an older text.
    let stale: Bool
    /// Called with whether the page went public, after either call landed.
    let onDone: @MainActor (_ published: Bool) async -> Void

    @State private var agreed = false
    @State private var sending = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            PageForm {
                if stale {
                    Section {
                        Label(PublishingConsent.stale, systemImage: "exclamationmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Text(PublishingConsent.intro)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PublishingConsent.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section { agreement }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Button {
                        Task { await confirm() }
                    } label: {
                        if sending {
                            ProgressView().frame(maxWidth: .infinity)
                                .accessibilityLabel("Публикуване")
                        } else {
                            Text(PublishingConsent.confirm).frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!agreed || sending)
                    .accessibilityInputLabels(A11y.spokenNames(PublishingConsent.confirm, "Публикувай", "Publish"))
                }
            }
            .inlineTitle(PublishingConsent.heading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(sending)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
            }
            .interactiveDismissDisabled(sending)
            // Said, not only drawn: the refusal appears above the button.
            .onChange(of: failure) { _, now in
                guard let now else { return }
                AccessibilityNotification.Announcement(now).post()
            }
        }
    }

    /// The sentence beside its switch, and above it at the accessibility
    /// sizes: beside, the switch left it a column too narrow for
    /// «страницата», which broke mid-word. `AnyLayout`, so the switch keeps
    /// its identity when the text size changes with the sheet open.
    /// VoiceOver hears the sentence once, as the switch's own label.
    private var agreement: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(PublishingConsent.agree)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Toggle(PublishingConsent.agree, isOn: $agreed)
                .labelsHidden()
                .disabled(sending)
                .accessibilityInputLabels(A11y.spokenNames("Съгласен", "Прочетох", "Agree"))
        }
    }

    private func confirm() async {
        guard agreed, !sending else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await FarmBrandAPI.consent(textVersion: PublishingConsent.version)
        } catch {
            failure = UserMessage.text(for: error)
            return
        }
        do {
            try await FarmBrandAPI.publish()
            await onDone(true)
            dismiss()
        } catch {
            // The consent stands. Asked again before another try, since the
            // next tap records it again.
            agreed = false
            failure = UserMessage.text(for: error)
            await onDone(false)
        }
    }
}
