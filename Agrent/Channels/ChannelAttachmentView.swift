import SwiftUI

/// A post's photo, or a player for its voice note (P9.6, #598).
///
/// The bytes are for MEMBERS only: anyone may read the post, but a
/// non-member's fetch answers 404, by design. So nothing is drawn until the
/// bytes arrive — never a broken player or an empty frame — and a 404 says
/// in one line why there is nothing to hear or see. The bytes are kept in
/// memory only (`no-store` on the server): never on disk on a phone that may
/// be lost or handed on.
struct ChannelAttachmentView: View {
    let postID: String
    let attachment: ChannelPost.Attachment

    @State private var data: Data?
    @State private var refused = false
    @State private var failed = false
    @State private var player = VoiceNotePlayer()

    var body: some View {
        Group {
            if let data {
                if attachment.isVoice {
                    voice(data)
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(VoiceNoteWords.photo)
                } else {
                    note("Снимката не може да бъде показана.")
                }
            } else if refused {
                note(VoiceNoteWords.membersOnly)
            } else if failed {
                note(attachment.isVoice ? "Записът не можа да бъде зареден." : "Снимката не можа да бъде заредена.")
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: postID) { await load() }
        .onDisappear { player.stop() }
    }

    private func voice(_ data: Data) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(data)
            } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.playing ? "Пауза" : "Пусни гласовото съобщение")
            .accessibilityInputLabels(player.playing ? A11y.spokenNames("Пауза", "Pause")
                                                     : A11y.spokenNames("Пусни", "Чуй", "Play"))
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceNoteWords.voice).font(.subheadline.weight(.semibold))
                if let ms = attachment.durationMs {
                    Text("\(VoiceNoteWords.clock(player.position)) / \(VoiceNoteWords.clock(ms: ms))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityLabel(VoiceNoteWords.spoken(ms: ms))
                }
            }
            if player.failed {
                Text("Записът не може да бъде пуснат.").font(.caption).foregroundStyle(Palette.error)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        guard data == nil else { return }
        do {
            data = try await ChannelsAPI.attachment(postID)
        } catch APIClient.APIError.http(let status, _, _, _, _) where status == 404 {
            refused = true
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
