import QuickLook
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
/// ── A treatment, and its ДНЕВНИК again (#320) ──
///
/// A folded treatment's row carries what was done — product, dose, period,
/// parcels — so those are shown from it, still without a fetch. Its PDF is
/// the one read here, and only on a tap: the screen right after a save is
/// not the only time a farmer needs the page an inspector asks for.
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
    var recorder: TreatmentRecorder = LiveTreatmentRecorder()

    @State private var generating = false
    @State private var failure: String?
    @State private var document: URL?

    /// The treatment this entry stands for — nil for an entry folded to
    /// itself, whose object says only that it is none.
    private var treatment: JournalTreatment? {
        entry.treatment.flatMap { $0.isTreatment ? $0 : nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                facts
                if let handle = treatment?.treatmentGroupId?.recorded {
                    documentAction(handle)
                }
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .inlineTitle("Запис")
        .quickLookPreview($document)
        // Removed when Quick Look closes, not on this screen's
        // `onDisappear`, which fires under the full-screen preview
        // (`FarmRecordAPI.removeGenerated`).
        .onChange(of: document) { _, now in
            if now == nil { FarmRecordAPI.removeGenerated() }
        }
        // Said, not only drawn: the button under the cursor came back.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }
    }

    // MARK: - Header

    /// The operator's own words, at the size of a thing being read rather
    /// than a thing being scanned.
    private var header: some View {
        Text(entry.displayTitle)
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
                Text(entry.occurredAt.map(BgDate.full) ?? LogEntry.noDate)
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

            if let treatment {
                treatmentFacts(treatment)
            }
        }
    }

    /// What was done, each fact only when the row has it: a fertilising has
    /// no pest and no period, and a «—» would read as one left blank.
    @ViewBuilder
    private func treatmentFacts(_ treatment: JournalTreatment) -> some View {
        let kind = treatment.treatmentKind
        if let product = treatment.productName?.recorded {
            LabelledFact(label: kind?.inputLabel ?? "Продукт") { factText(product) }
        }
        if let dose = treatment.doseText {
            LabelledFact(label: "Доза") {
                factText(dose).accessibilityLabel(treatment.doseSpoken ?? dose)
            }
        }
        if let pest = treatment.targetNote?.recorded {
            LabelledFact(label: "Вредител") { factText(pest) }
        }
        if let technique = ApplicationTechnique.display(treatment.applicationTechnique) {
            LabelledFact(label: "Техника") { factText(technique) }
        }
        if let days = treatment.quarantinePeriodDays {
            LabelledFact(label: "Карантинен срок") { factText(Plural.bg(days, "ден", "дни")) }
        }
        if let harvest = treatment.earliestHarvest {
            LabelledFact(label: "Най-ранна дата за прибиране") { factText(BgDate.full(harvest)) }
        }
        LabelledFact(label: "Парцели") {
            factText(Plural.bg(treatment.parcelCount, "парцел", "парцела"))
        }
        if let area = treatment.area {
            LabelledFact(label: kind == .fertilize ? "Наторена площ" : "Третирана площ") {
                factText(area.text).accessibilityLabel(area.spoken)
            }
        }
        if !treatment.blockNames.isEmpty {
            LabelledFact(label: treatment.blockNames.count == 1 ? "Блок" : "Блокове") {
                factText(treatment.blockNames.joined(separator: ", "))
            }
        }
    }

    private func factText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The treatment's ДНЕВНИК

    private func documentAction(_ handle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await download(handle) }
            } label: {
                if generating {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Изготвяне на PDF")
                } else {
                    Label("Изтегли PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(generating)
            .accessibilityInputLabels(A11y.spokenNames("Изтегли PDF", "Изтегли", "Download PDF", "Download"))

            Text(TreatmentSavedView.documentNote)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Text(failure)
                    .font(.body)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func download(_ handle: String) async {
        guard !generating else { return }
        generating = true
        failure = nil
        defer { generating = false }
        do {
            document = try await recorder.document(forTreatment: handle)
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    // MARK: - Notes

    /// The reason this screen exists.
    @ViewBuilder
    private var notes: some View {
        // Server notes are HTML — see RichText. An entry whose whole body
        // is an empty `<p></p>` therefore lands in the "no notes" branch
        // below rather than rendering as a blank area, which is the right
        // answer for both: there is nothing to read either way.
        let text = entry.notes
            .map(RichText.plainText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 8) {
            Text("Бележки")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

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
                    .foregroundStyle(Palette.secondaryText)
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element to VoiceOver: "Вид, Внасяне на препарат" rather than
        // two unrelated stops. DESIGN.md §5 is otherwise unstarted across the
        // app; this is not that work, it is just not adding to the debt.
        .accessibilityElement(children: .combine)
    }
}
