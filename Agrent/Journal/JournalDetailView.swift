import SwiftUI

/// One diary entry, in full.
///
/// The list could not be opened before this existed, which meant `notes` —
/// the substance of an entry, the part a person actually writes — was not
/// visible anywhere in the app. `JournalRow` renders title, type, date and
/// status and never touches `notes`, so an operator could see THAT something
/// was recorded and never WHAT. On a register the ДНЕВНИК PDF is generated
/// from, that is the difference between a list and a record.
///
/// ── Why this fetches nothing ──
///
/// The list endpoint returns whole `LogEntry` values, so every field shown
/// here is already in hand when the row is tapped. A `GET /journal/:id` on
/// push would add a spinner, a failure mode and an empty state to data that
/// cannot be missing. The cost is that an entry edited elsewhere since the
/// last list load shows the older text — which is the same staleness the list
/// itself carries, and `StaleBanner` above it already says so. If freshness
/// ever has to be exact here, the endpoint exists.
///
/// ── Why it is read-only ──
///
/// The server offers PUT/PATCH, DELETE, /restore and /purge on an entry. None
/// is wired up here on purpose: they are writes against a legally-filed
/// register, and which of them belongs on a phone — and behind what
/// confirmation — is a decision to take deliberately, in its own change, not
/// a button to add because the endpoint happened to exist.
///
/// ── Layout ──
///
/// Everything is a full-width row in one vertical stack. The list's own
/// `HStack` of chip + date is exactly what fails at accessibility sizes:
/// two flexible items sharing one line reflow independently and fight, and
/// the wide month name breaks mid-word when what is left is too narrow. A
/// detail screen has the whole width to spend, so nothing here shares a line
/// with anything else and there is no reflow to get wrong.
struct JournalDetailView: View {
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                facts
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Запис")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    /// The operator's own words, at the size of a thing being read rather
    /// than a thing being scanned.
    private var header: some View {
        Text(entry.title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabelledFact(label: "Вид") {
                CategoryChip(
                    text: entry.type.label,
                    foreground: entry.type.chipColors.foreground,
                    background: entry.type.chipColors.background
                )
            }

            LabelledFact(label: "Дата") {
                // `.month(.wide)` on its own full-width line. In the list it
                // shares an HStack with the chip and breaks mid-word once
                // Dynamic Type is turned up; here nothing competes for the
                // width, and `fixedSize` stops the stack squeezing it.
                Text(entry.occurredAt, format: .dateTime.day().month(.wide).year())
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabelledFact(label: "Статус") {
                Text(entry.status.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Notes

    /// The reason this screen exists.
    @ViewBuilder
    private var notes: some View {
        let text = entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 8) {
            Text("Бележки")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let text, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                // An entry with no notes is a real and ordinary state. Saying
                // so is better than a blank area that reads as a failure to
                // load — the screen should never be ambiguous about whether
                // it has nothing to show or has not shown it.
                Text("Няма бележки по този запис.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label above its value, never beside it.
///
/// Beside-it is the shape that fails: a label and a value on one line each
/// take what they can and neither can be told which should win, so at large
/// text sizes both wrap and the result is unreadable. Stacked, each gets the
/// full width and wraps only against the screen edge.
private struct LabelledFact<Content: View>: View {
    private let label: String
    private let content: Content

    // Explicit init rather than relying on `@ViewBuilder` propagating to the
    // synthesised memberwise initialiser. That propagation does work on
    // current toolchains, but this file cannot be compiled where it is
    // written — the only verifier is a CI round trip on a congested macOS
    // runner, so the unambiguous spelling is worth three lines.
    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element to VoiceOver: "Вид, Внасяне на препарат" rather than
        // two unrelated stops. DESIGN.md §5 is otherwise unstarted across the
        // app; this is not that work, it is just not adding to the debt.
        .accessibilityElement(children: .combine)
    }
}
