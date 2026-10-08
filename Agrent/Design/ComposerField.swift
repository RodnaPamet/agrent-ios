import SwiftUI

/// A few lines of writing, in the app's tokens: Борса's message composer
/// (#156) and a task's comment composer (#225).
///
/// Token-drawn rather than `.roundedBorder`, whose fill is system black in
/// dark mode and whose hairline nobody measured (#156). `Palette.Field` has
/// the pairs; the prompt is `Text.fieldPrompt`, so the hint is a token too,
/// not UIKit's placeholder grey. One field for both, so a fix to one is a
/// fix to the other.
struct ComposerField: View {
    /// Its name to VoiceOver, Voice Control and the tests.
    let title: String
    let prompt: String
    @Binding var text: String

    /// So a tap on the field's padding — inside its drawn edge, outside the
    /// text — focuses it, as `.roundedBorder`'s whole box did.
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: .fieldPrompt(prompt), axis: .vertical)
            .lineLimit(1...6)
            .foregroundStyle(Palette.Field.text)
            .focused($focused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // The tap is on the BACKGROUND, which only the padding exposes:
            // taps on the text still place the cursor.
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.Field.fill)
                    .onTapGesture { focused = true }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.Field.edge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(title)
    }
}
