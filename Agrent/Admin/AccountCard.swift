import SwiftUI

/// Who is signed in (owner, 2026-10-04): the picture or the initials, the
/// name, the email.
///
/// ── One card, two places (P2.8, 2026-10-06) ──
///
/// At the top of Админ, as a link to Профил, and on Профил itself, which
/// every role reaches from the menu. The SAME view in both, so the initials
/// rule, the layout and the spoken sentence cannot drift between them.
///
/// Read-only, and with no Изход on it: the card is identity, and Изход is a
/// row of its own on Профил (and in the menu), behind a confirmation.
///
/// ── From `CurrentUserStore`, never a request of its own for the text ──
///
/// The name and email are `/me`'s, which the launch already asked for. Only
/// the PICTURE is fetched here (`AccountAvatarStore`), only when the card is
/// on screen, and only when `/me` named one (`avatarUrl`) — nil asks nothing.
///
/// ── The email is personal data ──
///
/// It is drawn and it is spoken; it is never logged. Nothing in this file or
/// in `AccountAvatarStore` writes it to `Log`.
struct AccountCard: View {
    let user: CurrentUser
    var avatars: AccountAvatarStore = .shared

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The circle grows with the text beside it, so at the accessibility
    /// sizes it does not shrink to a dot next to a 40-point name.
    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 52

    var body: some View {
        // `AnyLayout`, as `MetaRow` does: side by side normally, STACKED at
        // the accessibility sizes, where a circle beside the text would take
        // a third of the width from an email that cannot wrap at a space.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))

        layout {
            AccountAvatarCircle(
                image: avatars.image(for: user.id, avatarURL: user.avatarUrl),
                initials: AccountInitials.of(name: user.name, email: user.email),
                diameter: diameter
            )
            VStack(alignment: .leading, spacing: 2) {
                if let name = Self.present(user.name) {
                    Text(name).font(.headline)
                }
                if let email = Self.present(user.email) {
                    // No `lineLimit`: an email has no spaces, so at large
                    // sizes it breaks between characters — ugly, but all of
                    // it is there, which a truncated address is not.
                    Text(verbatim: email)
                        .font(Self.present(user.name) == nil ? .headline : .subheadline)
                        .foregroundStyle(Self.present(user.name) == nil
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(Palette.secondaryText))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        // ONE element for VoiceOver: a picture, a name and an address read
        // as three stops, and the picture has nothing to say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(name: user.name, email: user.email))
        // Keyed on the VALUE as well as the user: the foreground `/me`
        // refresh can change `avatarUrl`, and that change is the one that
        // must fetch again (the store asks nothing for a value it holds).
        .task(id: AvatarTaskID(userID: user.id, avatarURL: user.avatarUrl)) {
            await avatars.load(for: user.id, avatarURL: user.avatarUrl)
        }
    }

    private struct AvatarTaskID: Equatable {
        let userID: String
        let avatarURL: String?
    }

    /// «Вписан като <name>, <email>», or as much of it as exists.
    static func spokenLabel(name: String?, email: String?) -> String {
        let parts = [present(name), present(email)].compactMap { $0 }
        return "Вписан като " + parts.joined(separator: ", ")
    }

    /// A blank string from the server is "not there", not an empty line.
    private static func present(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The circle: the picture when there is one, else the initials on the
/// account colour, else a person glyph (no name AND no email — `/me` allows
/// both to be null). Decorative: the card speaks for it.
struct AccountAvatarCircle: View {
    let image: UIImage?
    let initials: String?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Palette.Avatar.fill)
                Group {
                    if let initials {
                        // Sized from the circle, not from Dynamic Type: the
                        // circle already scales, and two letters must fit it
                        // at every size rather than overflow at the largest.
                        Text(verbatim: initials)
                            .font(.system(size: diameter * 0.4, weight: .semibold))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: diameter * 0.45))
                    }
                }
                .foregroundStyle(Palette.Avatar.ink)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
