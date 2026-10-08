import SwiftUI

/// One message, or its tombstone (agrent-ios#196, from Борса's #114).
///
/// ── Three speakers since agri-saas #1323 ──
///
/// Me, a colleague at my farm, and the other side — `MessageSpeaker`. Each
/// has its own caption and its own bubble (`Palette.Bubble`, where the three
/// pairs are measured): me solid gold, a colleague a gold tint with a gold
/// edge, both on the trailing side because both wrote for my farm; the other
/// side a neutral tint on the leading side. The caption says who in words,
/// so neither side nor colour is the only channel.
///
/// Under Increase Contrast every bubble gets an edge, as `CategoryChip` does,
/// so a pale fill on a pale page is still an object.
///
/// Any `ChatMessage`, as an existential rather than a generic: the bubble
/// reads a handful of values once per render, and a generic view would make
/// `MessageBubble.spoken` — which tests hold per speaker — need a type
/// argument it has no use for.
struct MessageBubble: View {
    let message: any ChatMessage
    let mayRetract: Bool
    let onRetract: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var speaker: MessageSpeaker { message.speaker }
    private var time: String { BgDate.messageTime(message.createdAt) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if speaker.isOurSide { Spacer(minLength: 48) }
            VStack(alignment: speaker.isOurSide ? .trailing : .leading, spacing: 4) {
                // The sender's name when the server has one (#1399), else
                // what they are to me; «Вие» for my own words. Aligned to its
                // own side when it wraps — a long name does even at the
                // default size — or a caption over my bubble would start at
                // the other side's edge and read as theirs.
                Text("\(speaker.caption(name: message.displayName)), \(time)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(speaker.isOurSide ? .trailing : .leading)
                bubble
            }
            if !speaker.isOurSide { Spacer(minLength: 48) }
        }
        // ONE element, spoken from the values — who, what, when. The speaker
        // first, so a colleague's words are never heard as the reader's own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MessageBubble.spoken(speaker: speaker, name: message.displayName,
                                                 body: bodyText, time: time))
        .accessibilityActions {
            if mayRetract {
                Button("Премахни", action: onRetract)
            }
        }
        // Long-press on the bubble. Only on MY OWN still-present messages
        // (never a colleague's: the server checks the person since #1323);
        // an empty menu is no menu.
        .contextMenu {
            if mayRetract {
                Button(role: .destructive, action: onRetract) {
                    Label("Премахни", systemImage: "trash")
                }
                .accessibilityInputLabels(A11y.Spoken.retract)
            }
        }
    }

    private var bodyText: String {
        message.isTombstone ? "Съобщението е премахнато" : (message.body ?? "")
    }

    /// The VoiceOver sentence: «Колега от стопанството, Мария Синтетична,
    /// Може и в петък, 09:00.» A static function so a test can hold it per
    /// speaker without a view.
    ///
    /// WHAT THEY ARE TO ME FIRST, in the app's own words, and then the name.
    /// On screen a sender's side and style say whose words these are;
    /// VoiceOver hears neither. A name is the sender's to choose — and
    /// commas in it are joined into this sentence as any other — so led by
    /// the name, the other side could be heard as a colleague, or as me.
    /// My own words are «Вие» alone.
    static func spoken(speaker: MessageSpeaker, name: String? = nil, body: String, time: String) -> String {
        var who = [speaker.label]
        if speaker != .me, let name { who.append(name) }
        return A11y.sentence(who + [body, time])
    }

    private var fill: Color {
        switch speaker {
        case .me: Palette.Bubble.mineFill
        case .colleague: Palette.Bubble.colleagueFill
        case .counterparty: Palette.Bubble.theirsFill
        }
    }

    private var ink: Color {
        switch speaker {
        case .me: Palette.Bubble.mineInk
        case .colleague: Palette.Bubble.colleagueInk
        case .counterparty: Palette.Bubble.theirsInk
        }
    }

    /// The colleague's edge is drawn ALWAYS — it is what separates a tinted
    /// gold bubble from the other side's tint at a glance. The other two get
    /// one under Increase Contrast only.
    private var edge: Color? {
        switch speaker {
        case .colleague: Palette.Bubble.colleagueEdge
        case .me: contrast == .increased ? Palette.accentDeep : nil
        case .counterparty: contrast == .increased ? Palette.secondaryText : nil
        }
    }

    @ViewBuilder
    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if message.isTombstone {
            // Keeps its place, says what happened, and is plainly not text
            // anybody wrote: italic, secondary, no fill.
            Text("Съобщението е премахнато")
                .italic()
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay { shape.strokeBorder(Palette.secondaryText.opacity(0.5), lineWidth: 1) }
        } else {
            // VERBATIM. Plain text after the server's sanitiser — never
            // markdown, never a `LocalizedStringKey`: `**` in a message is two
            // asterisks somebody typed.
            Text(verbatim: message.body ?? "")
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(fill, in: shape)
                .overlay {
                    if let edge {
                        shape.strokeBorder(edge, lineWidth: speaker == .colleague ? 1.5 : 1)
                    }
                }
        }
    }
}
