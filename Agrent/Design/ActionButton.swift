import SwiftUI

/// A screen's create action: in the navigation bar's trailing corner, the
/// RIGHTMOST item there (owner, 2026-11-06).
///
/// ── Top right, everywhere (owner, 2026-11-06) ──
///
/// "Move all '+' action buttons to the top right on the most right if other
/// buttons are there as well": Задачи's floating +, Борса's «Нова обява»,
/// the wide bars «Нов запис», «Нов разход» and «Ново мероприятие», and Риск's
/// «Застраховай». They had been where a gloved thumb reaches, the bottom of
/// the screen, then a floating capsule bottom left once the assistant's
/// button took the bottom right (2026-11-01). One place for "make a new
/// one" on every screen is the owner's call over the reach, and it leaves
/// the bottom of every screen to the list and the assistant.
///
/// ── Rightmost by being LAST ──
///
/// A bar lays out its `.primaryAction` items in the order they are written,
/// so this goes at the end of the screen's `.toolbar`, after «Филтри» or
/// «Съобщения», in the same block: two `.toolbar` modifiers make no promise
/// about the order of their items between them.
///
/// ── What it says ──
///
/// "+" in the bar, the action's name to VoiceOver and to the large content
/// viewer (a bar button shows it on a long press at the large text sizes),
/// and the name Voice Control answers to. A screen whose action isn't a
/// "new one" passes its own image (Риск's shield), or none to be written out.
struct ScreenAction: ToolbarContent {
    let title: String
    var systemImage: String? = "plus"
    /// `A11y.Spoken`'s names for it, Cyrillic first.
    let spoken: [String]
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: action) {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .accessibilityLabel(title)
            .accessibilityInputLabels(spoken)
        }
    }
}

extension View {
    /// `.borderedProminent` with the ink the accent is defined with.
    ///
    /// The system writes WHITE on a prominent button's tint, and the dark
    /// accent is gold: 2.10:1, the pair `Palette.onAccent` exists to stop.
    /// It was on «Нов запис» and «Нов разход» — the two actions a farmer
    /// performs standing in a field, on the bars P2.8 made solid — plus
    /// «Вход», «Опитай пак» and «Към обявите». `onAccent` on `accent` is
    /// 8.45 / 5.21 / 5.21, measured in `PaletteTokenTests`.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(Palette.onAccent)
    }
}
