import Foundation

/// A parcel's tasks as its screen from Блокове shows them (#462, owner
/// 2026-10-29): «Текущи», the work still to do, and «Архив», what was
/// finished or called off.
///
/// ── Split here, by status ──
///
/// The server sends one list, every status, newest first, and the split is
/// the client's (agreed with backend 1, 2026-10-29). One request answers both
/// tabs, and a task closed elsewhere moves between them on the next read,
/// with no second route and no query to keep in step.
struct ParcelTasks: Equatable, Sendable {
    let current: [WorkItemSummary]
    let archived: [WorkItemSummary]
    /// The server capped the list. Carried to the screen, as on Задачи: a
    /// capped list looks exactly like a complete short one.
    let truncated: Bool

    init(_ page: WorkItemPage) {
        current = page.items.filter { !$0.status.isArchived }
        archived = page.items.filter { $0.status.isArchived }
        truncated = page.truncated
    }

    var isEmpty: Bool { current.isEmpty && archived.isEmpty }

    /// Which half of the list is on screen.
    enum Tab: Hashable, CaseIterable {
        case current, archived

        var label: String {
            switch self {
            case .current: "Текущи"
            case .archived: "Архив"
            }
        }

        /// The tab with nothing in it, in a sentence.
        var emptyText: String {
            switch self {
            case .current: "Няма текущи задачи за този парцел."
            case .archived: "Няма задачи в архива за този парцел."
            }
        }
    }

    func rows(_ tab: Tab) -> [WorkItemSummary] {
        switch tab {
        case .current: current
        case .archived: archived
        }
    }
}

extension WorkItemStatus {
    /// Finished or called off: «Архив». Everything else is «Текущи», a
    /// status this app does not know yet included: work nobody has said is
    /// done stays in front of the reader rather than filed away.
    var isArchived: Bool {
        switch self {
        case .resolved, .closed, .canceled: true
        case .open, .triaged, .inProgress, .blocked, .pendingReview, .unknown: false
        }
    }
}

/// What the «Задачи» card on a parcel's screen says, from values: the
/// history cards' shape (`ParcelHistoryCard`), for a list split in two.
struct ParcelTasksCard: Equatable {
    static let title = "Задачи"

    /// «2 текущи». Nothing when there are none, which the line says in
    /// words, and nothing when the server capped the list: a count of a
    /// capped list is a claim the data cannot support.
    let count: String?
    /// The newest current task, or what there is instead.
    let line: ParcelHistoryLine
    /// Opens the list when there is anything in it, either tab. Pushing to
    /// two empty tabs would be a promise the screen cannot keep.
    let isTappable: Bool

    init(_ tasks: ParcelTasks, now: Date = Date()) {
        isTappable = !tasks.isEmpty
        if let newest = tasks.current.first {
            count = tasks.truncated ? nil : Plural.bg(tasks.current.count, "текуща", "текущи")
            line = ParcelHistoryLine(headline: newest.title,
                                     details: [newest.status.label, newest.rowDate(now: now)])
        } else if !tasks.archived.isEmpty {
            count = nil
            line = ParcelHistoryLine(details: [
                "Няма текущи задачи",
                tasks.truncated ? "Има задачи в архива" : "\(Plural.bg(tasks.archived.count, "задача", "задачи")) в архива",
            ])
        } else {
            count = nil
            line = ParcelHistoryLine(details: ["Няма задачи"])
        }
    }

    /// The card, for VoiceOver, from the values.
    var spoken: String { A11y.sentence([Self.title, count] + line.parts) }
}
