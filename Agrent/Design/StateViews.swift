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
/// `StaleBanner` WAS HERE, and it is gone on the owner's instruction.
///
/// It drew "обновено преди N минути" above every cached screen. Its
/// argument still stands — a screen rendering cached data without saying
/// how old it is cannot be told from a live one — and `CachedResource`
/// still marks a cached publish `.stale`, so the fact survives even though
/// nothing displays it.
///
/// What it cost was the pull-to-refresh gesture. The band sat above the
/// list, and three attempts at arranging it — a `safeAreaInset`, then a
/// VStack, then a VStack with a background — all still dragged the title
/// when the owner pulled. Борса was the one screen that behaved and the
/// one screen whose refresh he confirmed, so Борса's shape became the rule
/// and the band went with the rest of the chrome.
///
/// `Tests/StaleBannerCoverageTests.swift` went too. It asserted that every
/// cached screen shows its age, which is now false by design rather than
/// by accident — that is worth knowing if the question comes back.

/// A refusal or a withheld value: stated plainly, in the same weight as any
/// other row. Never red, never orange.
struct RefusalNote: View {
    let text: String
    var icon: String = "minus.circle"

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
    }
}

/// The genuine failure: the only red, and the only one with a way out.
struct ErrorState: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ScrollableState {
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
}

/// An empty state that can always be reached in full.
///
/// Same container as `ErrorState`, for the same reason — see `ScrollableState`.
struct EmptyState<Actions: View>: View {
    let title: String
    let icon: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(
        _ title: String,
        icon: String,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.message = message
        self.actions = actions
    }

    var body: some View {
        ScrollableState {
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text(message).font(.body)
            } actions: {
                actions()
            }
        }
    }
}

/// Centred while it fits, scrollable when it does not.
///
/// `ContentUnavailableView` centres its content and does NOT scroll, so at
/// large Dynamic Type sizes the description grows until the action button is
/// pushed off the bottom — behind the tab bar, still rendered, unreachable.
/// Observed on the calculator at accessibility3: "Опитай пак" sat underneath
/// the tab bar, faintly visible through it.
///
/// That is the same failure as the 102 KB error body that pushed this app's
/// retry button off screen in the first place — a state whose only exit
/// cannot be reached is worse than one with no exit, because it looks like it
/// has one.
///
/// `minHeight` on the content plus a scroll view means it stays optically
/// centred at ordinary sizes and becomes scrollable exactly when it has to.
struct ScrollableState<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
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

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            // WRAP, never truncate. Measured at accessibility3: the row's
            // chip rendered "Внасяне на препар…", and a category label with
            // its end cut off does not identify a category — on a regulated
            // diary, "Внасяне на препарат" truncated is the one row type a
            // person is most likely to be looking for.
            //
            // A chip is small, so the instinct is to keep it on one line and
            // let it clip. That is backwards: the chip is small because the
            // word is short at normal sizes, not because the word matters
            // less.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            // A pale tint on a white row is the whole chip: remove the
            // colour difference and it stops being an object and becomes
            // slightly-off-white space around a word. Under Increase
            // Contrast it gets an explicit edge, drawn in its own foreground
            // colour so no new value enters the palette.
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(foreground.opacity(0.55), lineWidth: 1)
                }
            }
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
        // Neither family, because this chip's colour IS the claim
        // "regulated" or "observational" and an unrecognised type supports
        // neither. Ochre would assert a new type is regulated when it may
        // not be; blue would assert it is not when it may be, on the
        // register where that distinction is the point. Neutral asserts
        // nothing, which is the only true thing available.
        case .unknown:
            (Palette.Chip.neutralText, Palette.Chip.neutralFill)
        }
    }
}
