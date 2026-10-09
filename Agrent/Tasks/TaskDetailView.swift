import SwiftUI

/// One task, in full.
///
/// ── Why this FETCHES, where the journal's detail does not ──
///
/// `JournalDetailView` takes its entry from the list and fetches nothing,
/// because the journal's list route returns whole entries — every field the
/// screen shows is already in hand when a row is tapped.
///
/// Tasks are the opposite. The list sends a projection of eleven keys; the
/// detail sends thirty-three. Description, resolution, source, the people
/// and the SLA exist ONLY here. Reusing the row would mean a screen
/// whose entire purpose is the fields the row does not carry.
///
/// That costs a spinner and a failure state, which is the honest price of
/// the data actually living somewhere else.
struct TaskDetailView: View {
    let summary: WorkItemSummary

    @State private var store: TaskDetailStore

    /// The close form is up (#226).
    @State private var closing = false

    /// Whether the open form asks about weeds — decided when the tick is
    /// tapped and kept, so the question cannot appear or vanish under the
    /// person's thumb when the parcels finish loading, and the note says
    /// what was asked.
    @State private var closeAsksWeeds = true

    /// A field operation's parcel lines (agrent-ios#138) — nil for every
    /// other kind of task. Decided from the ROW, so the lines start loading
    /// beside the task rather than after it; the web renders its
    /// `FieldOperationPanel` on exactly this condition.
    @State private var lines: FieldOperationStore?

    /// A comment being written (#225). Here rather than in the section, so
    /// it survives the task being re-read under it.
    @State private var commentDraft = ""

    /// Who is signed in — whether they may comment (`TaskCommentRules`).
    @State private var people = CurrentUserStore.shared

    /// Every OTHER kind of task's parcels, for its map (agrent-ios#177) —
    /// nil for a field operation, whose lines carry its map. Started beside
    /// the task, as the lines are, not after it.
    @State private var parcels: TaskParcelsStore?

    init(summary: WorkItemSummary) {
        self.summary = summary
        _store = State(initialValue: TaskDetailStore(id: summary.id))
        let isFieldOperation = summary.type == .fieldOperation
        _lines = State(initialValue: isFieldOperation
            ? FieldOperationStore(taskID: summary.id, taskKey: summary.key)
            : nil)
        _parcels = State(initialValue: isFieldOperation ? nil : TaskParcelsStore(taskID: summary.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // `key` is nullable on the wire — see `WorkItemSummary.key`. «Задача»
        // rather than the title: the title is already the first thing in the
        // content underneath, and a navigation bar repeating it says nothing
        // while costing the width that made `inlineTitle` necessary.
        .inlineTitle(summary.key ?? "Задача")
        .toolbar {
            if let item = store.state.value, TaskCloseRules.mayClose(item, me: people.user) {
                ToolbarItem(placement: .primaryAction) { closeButton }
            }
        }
        .sheet(isPresented: $closing) {
            CloseTaskSheet(asksWeeds: closeAsksWeeds) { answers in
                await close(with: answers)
            } cancel: {
                closing = false
            }
        }
        .writeFeedback(store.writeFeedback)
        .task { if store.state.value == nil { await store.load() } }
        .task { _ = await people.load() }
        // Here and not in the section: the section draws nothing until its
        // parcels arrive, and a task on an empty view is not one to rely on.
        .task { if let parcels, parcels.state.value == nil { await parcels.load() } }
        // The last line marked moved the job to PENDING_REVIEW on the
        // server; the chip above should say so without a pull.
        .onChange(of: lines?.finishedJob) { _, _ in
            Task { await store.load() }
        }
    }

    /// THE GREEN TICK (#226): the one status action on this screen, and it
    /// only completes the task — CLOSED, which it calls «Завърши» since the
    /// owner's 2026-10-09 wording (#236), as the status reads «Завършена».
    /// Owner, 2026-10-08 — the menu of every legal move it
    /// replaces is gone from the app; «В процес», «Блокирана» and «Отказана»
    /// are made on the web.
    ///
    /// Shown when the task can still be closed and this person may close it
    /// (`TaskCloseRules.mayClose`), so it is absent on a closed or canceled
    /// task rather than present and refused. Green is `Palette.success`, the
    /// success tick's colour, not the accent — on the bar 8.54 / 6.83 / 8.08
    /// (dark / light / «Слънце», `PaletteTokenTests`).
    private var closeButton: some View {
        Button {
            closeAsksWeeds = weedParcelIDs != []
            closing = true
        } label: {
            Label("Завърши задачата", systemImage: "checkmark")
        }
        .tint(Palette.success)
        .disabled(store.saving)
        .accessibilityLabel("Завърши задачата")
        .accessibilityInputLabels(A11y.Spoken.completeTask)
    }

    /// The parcels a close's weeds are recorded on: the task's own, as
    /// `GET /tasks/{id}/parcels` defines them — which for a field operation
    /// are its lines' parcels, the set the weed route checks against. nil
    /// while they are unknown: the question is still asked, and the weeds
    /// then reach the note only.
    private var weedParcelIDs: [String]? {
        if let lines {
            guard let detail = lines.state.value else { return nil }
            var seen = Set<String>()
            return detail.lines.map(\.parcel.id).filter { seen.insert($0).inserted }
        }
        return parcels?.state.value?.map(\.id)
    }

    /// The form's answers, sent. nil when the task closed — the sheet goes —
    /// or the refusal, which the sheet shows with the answers kept.
    private func close(with answers: TaskCloseAnswers) async -> String? {
        guard let item = store.state.value else { return TaskCloseText.inProgress }
        let asksWeeds = closeAsksWeeds
        let outcome = await store.close(
            resolution: TaskCloseRules.resolution(answers, asksWeeds: asksWeeds),
            weeds: asksWeeds ? TaskCloseRules.weedsToRecord(answers) : [],
            parcelIDs: weedParcelIDs ?? [],
            note: TaskCloseRules.observationNote(item))
        switch outcome {
        case .refused(let message):
            return message
        case .closed, .closedWithoutWeeds:
            closing = false
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            // The title and status are already known from the row, so the
            // wait is not blank. A spinner over nothing reads as "this
            // screen is broken"; a spinner under the thing you just tapped
            // reads as "the rest is coming".
            ScrollableState {
                VStack(alignment: .leading, spacing: 16) {
                    header(title: summary.title, status: summary.status)
                    ProgressView().frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let item, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(title: item.title, status: item.status)
                    if store.saving {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Записване…").font(.footnote).foregroundStyle(Palette.secondaryText)
                        }
                    }
                    if let closeNotice = store.closeNotice {
                        // The close landed and the weeds did not reach
                        // every parcel (#226). On the screen, not in a
                        // dialog that dismisses: the parcels' history is
                        // short of what the note says, and someone may want
                        // to add it on the web. The caveat colour — nothing
                        // the person did failed.
                        Text(closeNotice)
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // FIRST after the header, as the web puts its panel at
                    // the top of the overview: on a field operation the lines
                    // ARE the work, and the facts below describe it.
                    if let lines {
                        FieldOperationSection(store: lines)
                    }
                    // In the same place for every other task, so a task's
                    // parcels are where they are on a field operation.
                    if let parcels {
                        TaskParcelsSection(store: parcels)
                    }
                    facts(item)
                    text("Описание", item.description)
                    text("Решение", item.resolution)
                    related(item)
                    TaskCommentsSection(
                        comments: item.comments,
                        mayComment: TaskCommentRules.mayComment(people.user),
                        draft: $commentDraft,
                        sending: store.commenting,
                        failure: store.commentError
                    ) { text in
                        if await store.addComment(text) { commentDraft = "" }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable {
                await PullToRefresh.bounded {
                    await store.load()
                    await lines?.load(showCachedFirst: false)
                    await parcels?.load()
                }
            }
            .pageBackground()
        }
    }

    private func header(title: String, status: WorkItemStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            CategoryChip(
                text: status.label,
                foreground: status.chipColors.foreground,
                background: status.chipColors.background
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func facts(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            fact("Вид", item.type.label)
            // Importance only: priority overlapped it (owner, 2026-10-09, #236).
            fact("Важност", item.severity.label)
            if let op = item.operationType { fact("Операция", op.label) }
            if let due = item.dueAt {
                fact(
                    "Срок",
                    BgDate.full(due),
                    // Colour is not the only channel: the word is in the
                    // accessibility label too, via `fact`.
                    emphasised: item.isOverdue
                )
            }
            if let done = item.completedAt {
                fact("Завършена", BgDate.full(done))
            }
            if let who = item.assignee?.displayName { fact("Възложена на", who) }
            if let who = item.reviewer?.displayName { fact("Проверява", who) }
            if let who = item.createdBy?.displayName { fact("Създадена от", who) }
            if let created = item.createdAt { fact("Създадена", BgDate.full(created)) }

            // The server sends an `sla.label` too. It is not rendered — it is
            // a server-authored string and nothing establishes it is
            // Bulgarian. The breach is stated in words this app owns.
            if item.sla?.isBreached == true {
                RefusalNote(text: "Просрочен срок за реакция.", icon: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private func text(_ label: String, _ value: String?) -> some View {
        // Plain text, NOT RichText. `description` and `resolution` are
        // encrypted at rest and sanitised on write but arrive as plain text,
        // unlike journal notes which are rich-text HTML. Running them
        // through the converter would strip a `<` an agronomist typed.
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                Text(trimmed)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Counts, not contents. `comments`, `links` and `watchers` come back as
    /// arrays and were all empty on the task measured, so their element
    /// shapes are unknown — and guessing an element shape is exactly what
    /// cost the list screen its first run. A count is honest; the elements
    /// get modelled the day a screen reads them against a response that has
    /// some.
    @ViewBuilder
    private func related(_ item: WorkItem) -> some View {
        // No comments here since #225: they are on this screen, under it,
        // and «visible in the web app» would no longer be true of them.
        let parts: [String?] = [
            item.counts?.evidence.flatMap { $0 > 0 ? Plural.bg($0, "доказателство", "доказателства") : nil },
            item.counts?.links.flatMap { $0 > 0 ? Plural.bg($0, "връзка", "връзки") : nil },
        ]
        let present = parts.compactMap { $0 }
        if !present.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Свързани")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                // Stated, and stated as unavailable here. An operator who
                // can see "3 коментара" and cannot open them should be told
                // which it is, rather than tapping a number that does
                // nothing.
                ForEach(present, id: \.self) { Text($0).font(.body) }
                Text("Съдържанието им се вижда в уеб приложението.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
            Text(value)
                .font(.body)
                .foregroundStyle(emphasised ? Palette.error : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop per fact, and the emphasis said in words — colour is not
        // a channel everyone has.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([label, value, emphasised ? "просрочена" : nil]))
    }
}
