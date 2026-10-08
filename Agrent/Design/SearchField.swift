import SwiftUI

/// The app's own search field (agrent-ios#164): Борса's board search, drawn
/// in the app's colours rather than UIKit's.
///
/// ── Why not `.searchable` ──
///
/// `.searchable` hands its prompt to UIKit as a plain string, drawn in
/// `secondaryLabel` on `tertiarySystemFill`: 3.12:1 in light, under AA. No
/// styling reaches it — #166 read a styled `Text` prompt and an appearance
/// proxy back from a hosted field, both unchanged. Here the prompt is
/// `Text.fieldPrompt` on `Palette.Field.fill`, the composer's pair (#156):
///
///     prompt on the field     5.81   5.32   7.46   (dark / light / «Слънце»)
///
/// What the system's bar did that this keeps: the keyboard's Search key, a
/// clear button, and VoiceOver's "search field". What it does not: hiding
/// on scroll, and a Cancel button — the owner chose the contrast (2026-10-08).
///
/// ── One line, its prompt wrapping ──
///
/// VERTICAL, so the prompt wraps at the accessibility sizes instead of being
/// cut (`promptRoom`) — the system's bar cuts it. A vertical field takes
/// Return as a new line, and a search is one line: Return is the Search key
/// here, and submits.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    /// Runs the search. Also run when the field is cleared, so the board does
    /// not keep showing what the cleared words found.
    let submit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.Field.placeholder)
                .accessibilityHidden(true)
            TextField("Търсене", text: $text, prompt: .fieldPrompt(prompt), axis: .vertical)
                .promptRoom(prompt)
                .foregroundStyle(Palette.Field.text)
                .submitLabel(.search)
                .focused($focused)
                .onChange(of: text) { _, typed in
                    guard typed.contains("\n") else { return }
                    text = typed.replacingOccurrences(of: "\n", with: "")
                    focused = false
                    submit()
                }
                // NAMED, not left to its title: a field with a prompt reaches
                // VoiceOver with an EMPTY label and the prompt as its
                // placeholder (read back from the accessibility tree), so
                // with words typed it would be "search field" and no name.
                .accessibilityLabel("Търсене")
                .accessibilityAddTraits(.isSearchField)
                .accessibilityInputLabels(A11y.Spoken.search)
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.Field.placeholder)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Изчисти търсенето")
                .accessibilityInputLabels(A11y.Spoken.clearSearch)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        // The tap is on the BACKGROUND, which only the padding exposes: taps
        // on the text still place the cursor — the composer's arrangement.
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
    }

    private func clear() {
        text = ""
        submit()
    }
}
