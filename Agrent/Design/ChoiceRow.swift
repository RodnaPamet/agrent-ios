import SwiftUI

/// One choice to tap in a list of several: the page picker's row, with the
/// text and a check mark when chosen. VoiceOver says the check mark as
/// `.isSelected`, the system's own word.
///
/// The close form's weeds (#226) and «Нов запис»'s blocks (#254) both use it.
/// It moved here from the close form so the two lists look and speak alike.
struct ChoiceRow: View {
    let title: String
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No input label: a choice is DATA (a weed, a block's name), and
        // Voice Control answers to the visible text.
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
