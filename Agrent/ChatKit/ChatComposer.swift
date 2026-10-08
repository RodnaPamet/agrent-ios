import SwiftUI

/// The composer: the field, Send, the counter near the limit, the farm's
/// message pause and a failed send's line (agrent-ios#196, from Борса's
/// #114). The surface places it — pinned under the messages, on a solid bar
/// — and decides who may write.
///
/// The haptic for a send's outcome is NOT here: it belongs to the screen,
/// which `HapticSiteTests` counts per screen.
struct ChatComposer: View {
    @Binding var draft: String
    let sending: Bool
    /// `ChatPolicy.canSend`, with the surface's own refusal folded in.
    let canSend: Bool
    let sendFailure: String?
    let send: () async -> Void

    @State private var pause = RateLimitPause.messages

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sendFailure {
                failureLine(sendFailure)
            }
            // The farm's budget, not this conversation's: 60 messages a minute
            // shared by every colleague. Said with a clock time from the pause
            // itself, which re-renders this when it reopens. Not red — nothing
            // is broken, and the draft is still here.
            if let remaining = pause.remaining {
                Text(UserMessage.rateLimited(remaining: remaining))
                    .font(.footnote)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(title: "Съобщение", prompt: "Напишете съобщение…", text: $draft)
                sendButton
            }
            if let counter = ChatPolicy.counter(for: draft) {
                Text(counter.over ? "\(counter.text) — съобщението е твърде дълго" : counter.text)
                    .font(.footnote)
                    .foregroundStyle(counter.over ? Palette.error : Palette.secondaryText)
                    .accessibilityLabel(counter.over
                        ? "\(counter.spoken). Съобщението е твърде дълго."
                        : counter.spoken)
            }
        }
    }

    /// An ARROW, not the word «Изпрати». The outbox banner above every tab
    /// already says «Изпрати»; two visible controls with one word would be
    /// one spoken name for two different sends. The spoken name here says
    /// what is sent.
    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            Group {
                if sending {
                    ProgressView()
                } else {
                    // A label with its text kept, drawn as the glyph: the
                    // name is there for VoiceOver and the Large Content
                    // Viewer, not only in a modifier.
                    Label("Изпрати съобщението", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(!canSend)
        .accessibilityLabel("Изпрати съобщението")
        .accessibilityInputLabels(A11y.Spoken.sendMessage)
    }

    private func failureLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
}
