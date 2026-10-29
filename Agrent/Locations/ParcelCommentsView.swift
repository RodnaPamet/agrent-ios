import SwiftUI

/// A parcel's comments, newest first (#465): every comment on its tasks and
/// each closed task's closing note, which its «Коментари» card opens. A row
/// opens the task it is on.
struct ParcelCommentsView: View {
    let parcelName: String
    let store: ParcelCommentsStore

    var body: some View {
        content
            .inlineTitle(ParcelCommentsCard.title)
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
                    ForEach(comments.items) { comment in
                        NavigationLink(value: AppRoute.taskID(comment.taskId)) {
                            row(comment)
                        }
                    }
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
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
            Text(comment.task)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        // One stop, from the values, as a task's own comment is.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([comment.who, day, comment.text, "задача \(comment.task)"]))
    }
}
