import SwiftUI

/// A personal conversation in «Съобщения» (#593): who it is with, «Лично» so
/// it is not mistaken for a listing's thread, «Ново», and «Чака вашия
/// отговор» on a request that is mine to answer.
struct DirectInboxRow: View {
    let item: DirectInboxItem

    private var time: String { BgDate.messageTime(item.lastMessageAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(item.name).font(.headline)
                if item.unread {
                    CategoryChip(text: "Ново", foreground: Palette.Chip.activityText,
                                 background: Palette.Chip.activityFill)
                }
                CategoryChip(text: DirectWords.kind, foreground: Palette.Chip.neutralText,
                             background: Palette.Chip.neutralFill)
            }
            if item.awaitingMyAnswer == true {
                Label(DirectWords.awaiting, systemImage: "person.badge.clock")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(time)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibleRow(
            spoken: A11y.sentence([
                item.name,
                item.unread ? "ново" : nil,
                DirectWords.kind.lowercased(),
                item.awaitingMyAnswer == true ? DirectWords.awaiting.lowercased() : nil,
                time,
            ]),
            saying: A11y.spokenNames(item.name)
        )
    }
}
