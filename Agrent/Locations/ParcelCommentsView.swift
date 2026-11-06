import SwiftUI

/// A parcel's comments, newest first (#465): every comment on its tasks and
/// each closed task's closing note, which its «Коментари» card opens. A row
/// opens the task it is on.
struct ParcelCommentsView: View {
    let parcelName: String
    let store: ParcelCommentsStore
    /// The parcel, for «Нов коментар» (owner, 2026-11-06); nil offers none.
    var parcelID: String? = nil

    @State private var writing = false
    @State private var people = CurrentUserStore.shared
    /// A note swiped away (owner, 2026-11-06: deletable by its author or a
    /// farm OWNER/ADMIN), with the house's question and five seconds.
    @State private var removal: HistoryRemoval?
    @State private var asking: HistoryRemoval.Target?
    @State private var confirming = false

    /// Whether `comment` may be deleted by whoever is signed in: a parcel's
    /// own note, theirs, or any note for the farm's OWNER or ADMIN. The
    /// server's rule, so the swipe and its refusal agree.
    nonisolated static func mayDelete(_ comment: ParcelComment, me: CurrentUser?) -> Bool {
        guard comment.kind == .parcel, let me else { return false }
        if comment.createdBy?.id == me.id { return true }
        return ["OWNER", "ADMIN"].contains(me.role?.uppercased() ?? "")
    }

    var body: some View {
        content
            .inlineTitle(ParcelCommentsCard.title)
            // «+», top right, rightmost (`ScreenAction`): a note on the field.
            // For anyone but a READER, as on a task (`assertCanCommentOnTasks`,
            // which the route reuses), so a mechanisator in the field may.
            .toolbar {
                if parcelID != nil, TaskCommentRules.mayComment(people.user) {
                    ScreenAction(title: "Нов коментар", spoken: A11y.Spoken.newNote) { writing = true }
                }
            }
            .task { if removal == nil, let parcelID { removal = HistoryRemoval(parcelID: parcelID) } }
            .sheet(isPresented: $writing) {
                if let parcelID {
                    NewParcelNoteSheet(parcelID: parcelID) { Task { await store.load() } }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let comments, _):
            List {
                Group {
                    // Whose field: one push from the parcel.
                    Text(parcelName)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .listRowSeparator(.hidden)
                    if comments.truncated {
                        RefusalNote(
                            text: "Списъкът е съкратен от сървъра. Не всички коментари се показват.",
                            icon: "exclamationmark.triangle"
                        )
                    }
                    if comments.items.isEmpty {
                        Text("Няма коментари за този парцел.")
                            .font(.body)
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(comments.items.filter { !(removal?.isHidden($0.id) ?? false) }) { comment in
                        // A task's comment opens its task; a note on the
                        // parcel has none to open.
                        if let taskId = comment.taskId {
                            NavigationLink(value: AppRoute.taskID(taskId)) {
                                row(comment)
                            }
                        } else {
                            row(comment)
                                .historyRemovalSwipe(offered: removal != nil && Self.mayDelete(comment, me: people.user)) {
                                    asking = HistoryRemoval.Target(comment)
                                    confirming = true
                                }
                        }
                    }
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .modifier(NoteRemovalIfAny(removal: removal, asking: $asking, confirming: $confirming, store: store))
        }
    }

    private func row(_ comment: ParcelComment) -> some View {
        let day = comment.createdAt.map { BgDate.rowDay($0) }
        return VStack(alignment: .leading, spacing: 4) {
            MetaRow {
                if let who = comment.who {
                    Text(who).fontWeight(.medium)
                }
                if comment.who != nil, day != nil { MetaSeparator() }
                if let day {
                    Text(day).foregroundStyle(Palette.secondaryText)
                }
            }
            .font(.footnote)
            Text(comment.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let task = comment.task {
                Text(task)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        // One stop, from the values, as a task's own comment is.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([comment.who, day, comment.text, comment.task.map { "задача \($0)" }]))
    }
}

/// The notes' «Изтрий» chrome once the removal exists. Stateless: its
/// state is the list's (`historyRemoval`'s note).
private struct NoteRemovalIfAny: ViewModifier {
    let removal: HistoryRemoval?
    @Binding var asking: HistoryRemoval.Target?
    @Binding var confirming: Bool
    let store: ParcelCommentsStore

    func body(content: Content) -> some View {
        if let removal {
            content.historyRemoval(removal, asking: $asking, confirming: $confirming) { await store.load() }
        } else {
            content
        }
    }
}

