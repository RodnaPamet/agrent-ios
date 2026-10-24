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
/// ── Why this fetches (almost) nothing ──
///
/// The list endpoint returns whole `LogEntry` values, so every field shown
/// here is already in hand when the row is tapped. A `GET /journal/:id` on
/// push would add a spinner, a failure mode and an empty state to data that
/// cannot be missing. The cost is that an entry edited elsewhere since the
/// last list load shows the older text, which is the same staleness the list
/// itself carries. If freshness ever has to be exact here, the endpoint
/// exists.
///
/// A treatment's entry makes two reads, neither with a spinner or an empty
/// state. Until each answers, and if it can't, the screen is what it was:
/// - its progress (`UnfinishedTreatmentSection`, #326): whether every parcel
///   it was sent for reached the register, which the row can't say;
/// - its corrections (`TreatmentCorrectionsSection`, #392): «Коригирано на
///   … от …» and what each field said before.
///
/// ── Why it is read-only ──
///
/// The server offers PUT/PATCH and DELETE on an entry — /restore and /purge
/// were retired with «Кошче» (agri-saas #2254, 2026-10-24), and a DELETE now
/// erases. Neither is wired up here on purpose: they are writes against a
/// legally-filed register, and which of them belongs on a phone — and behind
/// what confirmation — is a decision to take deliberately, in its own change,
/// not a button to add because the endpoint happened to exist.
///
/// One such decision was taken (owner, 2026-10-15): an administrator may
/// abandon a treatment the server can't finish, from here
/// (`UnfinishedTreatmentSection`). That is the treatment route's own DELETE,
/// for incomplete treatments only. An entry's DELETE stays off the phone.
///
/// And a second (owner, 2026-10-24): «Коригирай» on a recorded treatment,
/// for its creator and the farm's administrators (#392). That is the
/// treatment's own correction route (`TreatmentCorrectionAPI`), under the
/// treatment's version, never the entry's PUT/PATCH.
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

    /// The treatment this entry stands for — nil for an entry folded to
    /// itself, whose object says only that it is none.
    /// The journal's own stack: «Виж на картата» pushes a route onto it (#399).
    @Environment(\.pushRoute) private var pushRoute

    @State private var people = CurrentUserStore.shared
    @State private var correcting = false
    /// What «Коригирай» saved, shown over the row this screen was opened
    /// with: the route carries a value, so the list reading again does not
    /// reach it.
    @State private var corrected: TreatmentCorrection.Saved?
    /// Bumped by each save, so «Корекции» reads the newest one in.
    @State private var trailRevision = 0
    /// The treatment's corrections (agri-saas #2292); nil until read.
    @State private var trail: TreatmentCorrectionTrail?
    /// How far the server got with it (#326); nil until read. Read here,
    /// not by its section, for the reason `UnfinishedTreatmentSection` gives.
    @State private var progress: TreatmentProgress?

    private var treatment: JournalTreatment? {
        guard let row = entry.treatment, row.isTreatment else { return nil }
        return corrected.map(row.applying) ?? row
    }

    /// The day, as corrected when it was.
    private var occurredAt: Date? {
        corrected?.definition.occurredOn.flatMap(BgDate.parseISODay) ?? entry.occurredAt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                facts
                if let trail, !trail.corrections.isEmpty {
                    // Under the facts it qualifies (#392): what they said
                    // before, and who changed them when.
                    TreatmentCorrectionsSection(trail: trail)
                }
                if let treatment, let handle = treatment.treatmentGroupId?.recorded {
                    // Which parcels, and where (#399, owner 2026-10-22): the
                    // row above says only how many.
                    Button {
                        pushRoute(.treatmentMap(handle: handle, title: TreatmentMapView.title(for: treatment.treatmentKind)))
                    } label: {
                        Label(TreatmentMapView.buttonTitle, systemImage: "map").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityInputLabels(A11y.Spoken.seeOnMap)
                }
                if let treatment, let handle = treatment.treatmentGroupId?.recorded,
                   TreatmentCorrection.offered(entry, to: people.user) {
                    Button {
                        correcting = true
                    } label: {
                        Label(TreatmentCorrection.actionTitle, systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityInputLabels(A11y.Spoken.correctTreatment)
                    .sheet(isPresented: $correcting) {
                        TreatmentCorrectionFlow(handle: handle, row: treatment) { saved in
                            corrected = saved
                            trailRevision += 1
                            AccessibilityNotification.Announcement("Корекцията е запазена.").post()
                        }
                    }
                }
                if let handle = treatment?.treatmentGroupId?.recorded {
                    if let progress, !progress.complete {
                        UnfinishedTreatmentSection(handle: handle, progress: $progress)
                    }
                    TreatmentDocumentAction(handle: handle)
                }
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .inlineTitle("Запис")
        .task(id: TrailKey(handle: treatment?.treatmentGroupId?.recorded, revision: trailRevision)) {
            await readTrail()
        }
        .task(id: treatment?.treatmentGroupId?.recorded) {
            guard let handle = treatment?.treatmentGroupId?.recorded else { return }
            progress = await UnfinishedTreatmentSection.read(handle)
        }
    }

    private struct TrailKey: Hashable {
        let handle: String?
        let revision: Int
    }

    /// «Корекции», for any treatment: the read is open to everyone who can
    /// see it. A failure keeps what was there, which is nothing at first.
    private func readTrail() async {
        guard let handle = treatment?.treatmentGroupId?.recorded,
              let read = try? await TreatmentCorrectionAPI.corrections(handle) else { return }
        trail = read
    }

    // MARK: - Header

    /// The operator's own words, at the size of a thing being read rather
    /// than a thing being scanned.
    private var header: some View {
        // The treatment's product as corrected, when it was: the title is
        // the product (`displayTitle`), and the server retitles a corrected
        // product's entries (agri-saas #2293).
        Text(treatment?.foldedProduct ?? entry.displayTitle)
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
                Text(occurredAt.map(BgDate.full) ?? LogEntry.noDate)
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
    /// no pest and no period, and a «—» would read as one left blank. The
    /// product is the screen's title already (`displayTitle`), so it is not
    /// said a second time.
    @ViewBuilder
    private func treatmentFacts(_ treatment: JournalTreatment) -> some View {
        let kind = treatment.treatmentKind
        if let dose = treatment.doseText {
            LabelledFact(label: "Доза") {
                factText(dose).accessibilityLabel(treatment.doseSpoken ?? dose)
            }
        }
        if let pest = treatment.targetNote?.recorded {
            LabelledFact(label: "Вредител") { factText(pest) }
        }
        if let stage = treatment.phenophase?.recorded {
            LabelledFact(label: "Фенофаза/BBCH") { factText(stage) }
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
