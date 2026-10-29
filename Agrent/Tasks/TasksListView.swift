import SwiftUI

/// The work an operator has to do, on the device they do it with.
///
/// This replaced Админ in the tab bar (owner, 2026-09-22). Five slots exist
/// before iOS collapses the rest into "More", and Админ was spending the most
/// valuable one on a placeholder that said "use the web app" — while the
/// surface an operator opens many times a day would have sat behind a menu.
/// That inverts the frequencies. Админ moved into `AppMenuButton`, which is
/// what a monthly action is for.
struct TasksListView: View {
    @State private var store = TasksStore()
    @State private var permission = PushPermission.shared
    @State private var people = CurrentUserStore.shared
    /// Rows swiped away, inside their five seconds or just sent (#454).
    @State private var removal = TaskRemoval()
    /// The row whose «Изтрий» is being asked about (owner, 2026-10-26).
    @State private var confirmingRemoval: WorkItemSummary?
    @State private var confirming = false
    /// A delete the server refused is being said.
    @State private var refused = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        RoutedStack {
            // Chrome in a VStack above the scrollable — Борса's
            // arrangement, the one confirmed by use. See
            // `JournalListView` for why this is no longer a
            // `safeAreaInset(edge: .top)`.
            // Борса's shape — see `JournalListView` for what it costs.
            // «Нова задача», at the bottom right (owner, 2026-10-20, #372).
            //
            // A ZStack layer, NOT an `.overlay` (#388). The button presents
            // «Нова задача» as a sheet, and a sheet presented from inside an
            // overlay showed on screen but never reached the accessibility
            // tree: VoiceOver, Voice Control and XCUITest saw the list under
            // it, so the form couldn't be used with them. Found by A11yShots
            // `testNewTaskParcelsStep`.
            ZStack(alignment: .bottomTrailing) {
                content
                    .background(Palette.Surface.page)
                NewTaskButton { await store.load() }
            }
            // Under the list and the +, as on Дневник: what went, and
            // «Отмени» for its five seconds.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let undoable = removal.undoable { undoBar(undoable) }
            }
            .navigationTitle("Задачи")
            .appMenu()
            .alert(TaskRemoval.confirmTitle, isPresented: $confirming, presenting: confirmingRemoval) { item in
                Button(TreatmentRemoval.actionTitle, role: .destructive) { remove(item) }
                    .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: { item in
                Text(item.title)
            }
            .alert("Задачата не е изтрита", isPresented: $refused, presenting: removal.failure) { _ in
                Button("Затвори", role: .cancel) { removal.dismissFailure() }
            } message: { failure in
                Text(failure)
            }
            .onChange(of: removal.failure) { _, failure in
                refused = failure != nil
            }
            // The server took a delete: the list as it now stands, and any
            // sent row it no longer lists stops being hidden.
            .onChange(of: removal.deletions) {
                Task {
                    await store.load()
                    removal.listRead()
                }
            }
            .task { if store.state.value == nil { await store.load() } }
            .task { _ = await people.load() }
            // Where iOS stands on notifications, for the card — again on a
            // return, as the person may have been to Settings (#272).
            .task { await permission.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await permission.refresh() } }
            }
        }
    }

    /// In the CONTENT, not the navigation bar — the same reason as the
    /// journal's. A large navigation title truncates and cannot be told not
    /// to; as content it wraps.

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let page, _) where page.items.isEmpty:
            EmptyState(
                "Няма задачи",
                icon: "checklist",
                message: "Няма задачи за това стопанство."
            )

        case .loaded(let page, _):
            List {
                // The ask for notifications, beside the tasks they would be
                // about (owner, 2026-10-14). Gone once answered or closed —
                // decided HERE, as a row that draws nothing can still leave
                // a blank one in a List.
                if permission.showsCard {
                    PushInviteRow()
                        .cardRow()
                }
                // Said out loud, because a capped list looks exactly like a
                // complete short one. There is nothing on screen to notice,
                // which is what makes it worse than an empty list rather
                // than milder.
                if page.truncated {
                    RefusalNote(
                        text: "Списъкът е съкратен от сървъра. Не всички задачи се показват.",
                        icon: "exclamationmark.triangle"
                    )
                    .pageRow()
                }
                // What the list shows: a row swiped away isn't counted.
                Section(titled: Plural.bg(visible(page.items).count, "задача", "задачи")) {
                ForEach(visible(page.items)) { item in
                    NavigationLink(value: AppRoute.task(item)) {
                        TaskRow(item: item)
                    }
                    .pageRow()
                    // Not a full swipe: «Изтрий», then the question, then
                    // five seconds of «Отмени» (owner, 2026-10-26), as on
                    // Дневник. Only where the server says it would succeed.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if TaskRemoval.offered(item, to: people.user) {
                            Button(role: .destructive) {
                                confirmingRemoval = item
                                confirming = true
                            } label: {
                                Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                            }
                            .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                        }
                    }
                }
                }
            }
            .listStyle(.plain)
            .pageBackground()
            // The last row scrolls clear of the + rather than under it.
            .contentMargins(.bottom, 96, for: .scrollContent)
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    /// The rows the list shows: the server's, less what was swiped away.
    private func visible(_ items: [WorkItemSummary]) -> [WorkItemSummary] {
        removal.hidden.isEmpty ? items : items.filter { !removal.hidden.contains($0.id) }
    }

    /// The confirmed «Изтрий»: the row goes, the five seconds start, and it
    /// is said, with the way back.
    private func remove(_ item: WorkItemSummary) {
        removal.remove(item, window: voiceOver || switchControl ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(TaskRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }

    /// What went, with «Отмени», for the five seconds before it is sent:
    /// Дневник's bar, for a task.
    private func undoBar(_ undoable: TaskRemoval.Undoable) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TaskRemoval.removedText(undoable))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { removal.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}

struct TaskRow: View {
    let item: WorkItemSummary
    /// Off on a list of the person's own tasks (#465), where every row
    /// would carry their own name.
    var showsAssignee = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            AdaptiveRow { statusChip; meta }

            // When it was opened, or completed (owner, 2026-10-09, #236): a
            // line of its own under the chip, worded in full, so it never
            // reads as the due date beside it.
            if let dated = item.rowDate() {
                Text(dated)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        // One stop, spoken from the values — never from the rendered text,
        // which carries a `·` that VoiceOver reads as "middle dot".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            item.title,
            item.status.label,
            severityText,
            assigneeName.map { "възложена на \($0)" },
            dueText,
            item.isOverdue ? "просрочена" : nil,
            item.rowDate(),
        ]))
    }

    private var statusChip: some View {
        CategoryChip(
            text: item.status.label,
            foreground: item.status.chipColors.foreground,
            background: item.status.chipColors.background
        )
    }

    /// Severity is the only urgency signal a row has — priority overlapped
    /// it and is gone from the app (#236). Shown only when it is one an
    /// operator should act on — MEDIUM on every row would be noise, and
    /// noise in the urgency channel is worse than an empty one.
    private var severityText: String? {
        switch item.severity {
        case .critical, .high: item.severity.label
        case .info, .low, .medium, .unknown: nil
        }
    }

    private var assigneeName: String? {
        showsAssignee ? item.assignee?.displayName : nil
    }

    /// Named, now the row carries a second date (#236): a bare «1 октомври»
    /// beside «Отворена на 20 септември» would leave a reader to guess which
    /// is the deadline.
    private var dueText: String? {
        item.dueAt.map { "Срок \(BgDate.rowDay($0))" }
    }

    @ViewBuilder
    private var meta: some View {
        // THREE flexible values, which is the worst case in the app: at
        // accessibility5 an HStack gave each of them about four characters.
        MetaRow {
            if let severityText {
                Text(severityText).foregroundStyle(Palette.error)
            }
            if let dueText {
                if severityText != nil { MetaSeparator() }
                // Overdue is carried by COLOUR here, so it is also carried by
                // a word in the accessibility label above. Colour alone is
                // not a channel everyone has.
                Text(dueText)
                    .foregroundStyle(item.isOverdue ? Palette.error : Palette.secondaryText)
            }
            if let who = assigneeName {
                if severityText != nil || dueText != nil {
                    MetaSeparator()
                }
                // The cap was right when this shared a line with two other
                // values and wrong once it has a line of its own: a name is
                // the whole point of "who is this assigned to".
                Text(who)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension WorkItemSummary {
    /// The date a row carries (owner, 2026-10-09, #236): when the task was
    /// completed, once it is and the list says when; otherwise when it was
    /// opened. In the web's words — «Завършена на» is its detail label.
    ///
    /// The list does not send `completedAt` yet (see it), so a completed row
    /// says when it was OPENED, and says that — never `updatedAt` passed off
    /// as the completion. A CANCELED task was not completed and gets the
    /// date it was opened, too.
    func rowDate(now: Date = Date()) -> String? {
        if status == .resolved || status == .closed, let completedAt {
            return "Завършена на \(BgDate.rowDay(completedAt, now: now))"
        }
        return createdAt.map { "Отворена на \(BgDate.rowDay($0, now: now))" }
    }
}

extension WorkItemStatus {
    /// Three groups, not eight colours. A row is scanned, not read: what an
    /// operator needs at a glance is "needs me / in hand / done", and eight
    /// tints would make that harder rather than more precise.
    ///
    /// The accent family is reused rather than extended — see `Palette`,
    /// which keeps green for parcel state on the map and forbids it as an
    /// app accent for exactly this kind of reason.
    var chipColors: (foreground: Color, background: Color) {
        switch self {
        case .open, .triaged:
            (Palette.Chip.inputText, Palette.Chip.inputFill)
        case .inProgress, .blocked, .pendingReview:
            (Palette.Chip.activityText, Palette.Chip.activityFill)
        case .resolved, .closed, .canceled, .unknown:
            (Palette.Chip.neutralText, Palette.Chip.neutralFill)
        }
    }
}
