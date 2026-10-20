import SwiftUI

/// The words of the notification ask, the card's and Профил's alike
/// (owner, 2026-10-14).
enum PushText {
    static let invite = "Получавайте известие, когато Ви възложат задача или има предупреждение за времето."
    static let turnOn = "Включи"
    static let closeInvite = "Затвори"
    static let switchTitle = "Известия"
    static let switchOnNote = "Известие, когато Ви възложат задача или има предупреждение за времето."
    static let refusedNote = "Известията от Agrent са изключени в Настройки на телефона."
    static let openSettings = "Отвори Настройки"
}

/// The card at the top of «Задачи» that asks for notifications
/// (agrent-ios#272).
///
/// A LIST ROW, not chrome above the list: a band above the scrollable is
/// what cost pull-to-refresh on every screen that had one (see
/// `StateViews.swift`), and this one has two buttons a farmer could catch
/// mid-pull. It scrolls away with the tasks and comes back with them.
///
/// The iOS prompt appears only after «Включи», so the person has read why
/// before iOS asks the one time it will. Whether it shows at all is the
/// list's to decide (`PushPermission.showsCard`).
struct PushInviteRow: View {
    @State private var permission = PushPermission.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(PushText.invite)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PushText.turnOn) {
                    Task { await permission.turnOn() }
                }
                .prominentButton()
                .accessibilityInputLabels(A11y.spokenNames(PushText.turnOn, "Turn on"))
            }
            Spacer(minLength: 0)
            Button {
                permission.closeCard()
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Palette.secondaryText)
            .accessibilityLabel(PushText.closeInvite)
            .accessibilityInputLabels(A11y.Spoken.close)
        }
        // Each button its own target inside the row, rather than the whole
        // row one tap that fires both.
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
