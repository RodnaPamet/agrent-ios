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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                header
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .appMenu()
            .task { if store.state.value == nil { await store.load() } }
        }
    }

    /// In the CONTENT, not the navigation bar — the same reason as the
    /// journal's. A large navigation title truncates and cannot be told not
    /// to; as content it wraps.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Задачи")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let page = store.state.value {
                Text(Plural.bg(page.items.count, "задача", "задачи"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

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
                // Said out loud, because a capped list looks exactly like a
                // complete short one. There is nothing on screen to notice,
                // which is what makes it worse than an empty list rather
                // than milder.
                if page.truncated {
                    RefusalNote(
                        text: "Списъкът е съкратен от сървъра. Не всички задачи се показват.",
                        icon: "exclamationmark.triangle"
                    )
                }
                ForEach(page.items) { item in
                    NavigationLink { TaskDetailView(summary: item) } label: {
                        TaskRow(item: item)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }
}

struct TaskRow: View {
    let item: WorkItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Side by side while they fit, stacked when they do not. The
            // journal row's lesson: two flexible children on one line reflow
            // independently and fight at large Dynamic Type, and the result
            // is a chip wrapped to three lines beside a date broken mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { statusChip; meta }
                VStack(alignment: .leading, spacing: 6) { statusChip; meta }
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
            item.assignee?.displayName.map { "възложена на \($0)" },
            dueText,
            item.isOverdue ? "просрочена" : nil,
        ]))
    }

    private var statusChip: some View {
        CategoryChip(
            text: item.status.label,
            foreground: item.status.chipColors.foreground,
            background: item.status.chipColors.background
        )
    }

    /// `priority` is NOT in the list projection, so severity is the only
    /// urgency signal a row has. Shown only when it is one an operator
    /// should act on — MEDIUM on every row would be noise, and noise in the
    /// urgency channel is worse than an empty one.
    private var severityText: String? {
        switch item.severity {
        case .critical, .high: item.severity.label
        case .info, .low, .medium, .unknown: nil
        }
    }

    private var dueText: String? {
        item.dueAt.map(BgDate.dayMonth)
    }

    @ViewBuilder
    private var meta: some View {
        HStack(spacing: 6) {
            if let severityText {
                Text(severityText).foregroundStyle(Palette.error)
            }
            if let dueText {
                if severityText != nil { Text("·").foregroundStyle(.secondary) }
                // Overdue is carried by COLOUR here, so it is also carried by
                // a word in the accessibility label above. Colour alone is
                // not a channel everyone has.
                Text(dueText)
                    .foregroundStyle(item.isOverdue ? Palette.error : .secondary)
            }
            if let who = item.assignee?.displayName {
                if severityText != nil || dueText != nil {
                    Text("·").foregroundStyle(.secondary)
                }
                Text(who).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
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
