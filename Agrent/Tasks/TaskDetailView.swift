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
/// detail sends thirty-three. Description, resolution, priority, source, the
/// people and the SLA exist ONLY here. Reusing the row would mean a screen
/// whose entire purpose is the fields the row does not carry.
///
/// That costs a spinner and a failure state, which is the honest price of
/// the data actually living somewhere else.
struct TaskDetailView: View {
    let summary: WorkItemSummary

    @State private var store: TaskDetailStore

    init(summary: WorkItemSummary) {
        self.summary = summary
        _store = State(initialValue: TaskDetailStore(id: summary.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let age = store.state.freshness?.ageDescription {
                StaleBanner(age: age)
            }
            content
        }
        .navigationTitle(summary.key)
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.state.value == nil { await store.load() } }
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
                    facts(item)
                    text("Описание", item.description)
                    text("Решение", item.resolution)
                    related(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable { await store.load() }
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
            fact("Приоритет", item.priority.label)
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
            fact("Създадена", BgDate.full(item.createdAt))

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
                    .foregroundStyle(.secondary)
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
        let parts: [String?] = [
            item.counts?.comments.flatMap { $0 > 0 ? "^[\($0) коментара](inflect: true)" : nil },
            item.counts?.evidence.flatMap { $0 > 0 ? "^[\($0) доказателства](inflect: true)" : nil },
            item.counts?.links.flatMap { $0 > 0 ? "^[\($0) връзки](inflect: true)" : nil },
        ]
        let present = parts.compactMap { $0 }
        if !present.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Свързани")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Stated, and stated as unavailable here. An operator who
                // can see "3 коментара" and cannot open them should be told
                // which it is, rather than tapping a number that does
                // nothing.
                ForEach(present, id: \.self) { Text($0).font(.body) }
                Text("Съдържанието им се вижда в уеб приложението.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
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
