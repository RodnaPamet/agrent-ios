import SwiftUI

/// The four kinds of "not the happy path", which the design canvas separates
/// deliberately — and only ONE of them is an error.
///
///   СЪСТОЯНИЕ   cached data, with its age. Calm and factual: no network is
///               an honest answer, not a fault.
///   ОТКАЗ       the server declined to produce a figure. That is the product
///               being honest and must not look broken.
///   ЗАДЪРЖАНО   data withheld pending consent. Its absence is the feature.
///   ГРЕШКА      actually broken — the only one in `Palette.error`, and the
///               only one that offers a way out.
///
/// This existed before as three different ad-hoc treatments: a yellow banner
/// for staleness and orange text for refusals, both of which told an operator
/// something was wrong while the app was working correctly.
struct StaleBanner: View {
    let age: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Последно обновено \(age)")
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// A refusal or a withheld value: stated plainly, in the same weight as any
/// other row. Never red, never orange.
struct RefusalNote: View {
    let text: String
    var icon: String = "minus.circle"

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// The genuine failure: the only red, and the only one with a way out.
struct ErrorState: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Неуспешно зареждане")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Palette.error)
            }
        } description: {
            Text(message).font(.body)
        } actions: {
            Button("Опитай пак") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// A short, high-contrast category label.
///
/// Replaces the type being one more grey word in a run of grey words: at
/// arm's length in sunlight, a chip is findable and a sentence is not.
struct CategoryChip: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}

extension LogEntryType {
    /// Input applications are the regulated ones — they get the ochre family;
    /// everything observational gets the blue.
    var chipColors: (foreground: Color, background: Color) {
        switch self {
        case .inputApplication, .seeding, .transplanting, .irrigation:
            (Palette.Chip.inputText, Palette.Chip.inputFill)
        case .activity, .observation, .harvest, .maintenance, .labTest, .grazing:
            (Palette.Chip.activityText, Palette.Chip.activityFill)
        }
    }
}
