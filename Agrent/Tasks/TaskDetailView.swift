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

    /// The status being moved to, while its resolution is being written.
    /// Non-nil means the sheet is up.
    @State private var resolving: WorkItemStatus?

    init(summary: WorkItemSummary) {
        self.summary = summary
        _store = State(initialValue: TaskDetailStore(id: summary.id))
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
            if let item = store.state.value, !item.status.allowedNext.isEmpty {
                ToolbarItem(placement: .primaryAction) { statusMenu(item) }
            }
        }
        .sheet(item: $resolving) { target in
            ResolutionSheet(target: target) { text in
                resolving = nil
                Task { await store.setStatus(target, resolution: text) }
            } cancel: {
                resolving = nil
            }
        }
        .task { if store.state.value == nil { await store.load() } }
    }

    /// ONLY THE LEGAL MOVES.
    ///
    /// The server enforces `WORK_ITEM_TRANSITIONS` and refuses the rest —
    /// measured: `IN_PROGRESS → OPEN` comes back 400 "Illegal work-item
    /// transition". Offering a button that cannot work tells an operator the
    /// app is broken when they asked for something that was never possible,
    /// and the refusal arrives in English besides.
    ///
    /// The menu is absent entirely on CLOSED and CANCELED, which are sinks.
    /// A disabled menu invites tapping; no menu says the task is finished.
    @ViewBuilder
    private func statusMenu(_ item: WorkItem) -> some View {
        Menu {
            ForEach(item.status.allowedNext, id: \.self) { next in
                Button(next.label) {
                    // A terminal status needs a resolution, and the server
                    // checks it AFTER sanitising — so a resolution of pure
                    // markup is refused rather than stored as something that
                    // renders as nothing. Asking for it here means the
                    // operator writes it once, on the screen, instead of
                    // meeting a 400.
                    if next.requiresResolution {
                        resolving = next
                    } else {
                        Task { await store.setStatus(next, resolution: nil) }
                    }
                }
            }
        } label: {
            Label("Промени статуса", systemImage: "arrow.triangle.swap")
        }
        .disabled(store.saving)
        .accessibilityLabel("Промени статуса")
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
                            Text("Записване…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let writeError = store.writeError {
                        // Stated on the screen, not in a dialog that
                        // dismisses. A refused write whose message has gone
                        // reads as a write that worked.
                        Text(writeError)
                            .font(.footnote)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    facts(item)
                    text("Описание", item.description)
                    text("Решение", item.resolution)
                    related(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
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
            item.counts?.comments.flatMap { $0 > 0 ? Plural.bg($0, "коментар", "коментара") : nil },
            item.counts?.evidence.flatMap { $0 > 0 ? Plural.bg($0, "доказателство", "доказателства") : nil },
            item.counts?.links.flatMap { $0 > 0 ? Plural.bg($0, "връзка", "връзки") : nil },
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

/// The resolution a terminal status requires.
///
/// The server demands a non-empty resolution for RESOLVED, CLOSED and
/// CANCELED, and checks it AFTER `sanitizePlainText` — so a body of pure
/// markup is refused rather than stored as something that renders as
/// nothing. The Създай button therefore stays disabled until there is text
/// that would survive that, which turns a 400 into a button that is simply
/// not ready yet.
private struct ResolutionSheet: View {
    let target: WorkItemStatus
    let confirm: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""

    /// Mirrors the server's check as closely as a client can: trimmed, and
    /// with anything tag-shaped removed, because that is what it will be
    /// measured against.
    private var isUsable: Bool {
        !RichText.plainText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Решение") {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
                Section {
                    Text("Изисква се, за да се завърши задачата.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .inlineTitle(target.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { confirm(text) }.disabled(!isUsable)
                }
            }
        }
    }
}

/// So the sheet can be driven by `sheet(item:)`, which carries the target
/// status with it — a separate Bool plus a stored status can disagree, and
/// the disagreement is a write sent to the wrong state.
extension WorkItemStatus: Identifiable {
    public var id: String { rawValue }
}
