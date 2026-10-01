import SwiftUI

/// Админ: the farm, the app, the people — three rows.
///
/// Reached from the app menu rather than a tab: five tab slots exist before
/// iOS collapses the rest into "More", and this is a monthly action while
/// Задачи is a daily one. Operator frequency decides the tab bar.
///
/// ── THREE ROWS, IN THE OWNER'S ORDER (2026-10-01) ──
///
///     «Стопанство»   → the farm profile, which can now be edited
///     «Долна лента»  → the bottom-bar editor
///     «Потребители»  → the members, with their count
///
/// This screen used to BE the member list, with the farm's identity block
/// under it. Each now has its own page (`FarmProfileView`, `MembersView`) and
/// this one is the index. The farm comes first because it is what the
/// administration is OF; the members are the longest page and go last.
///
/// One store for all three. The rows show a member count and the producer's
/// name, so they read the same data the pages do — and a deactivation on the
/// members page is reflected in the count on the way back.
struct AdminView: View {
    @State private var store = AdminStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Админ")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { await store.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.access {
        case .forbidden:
            // A REAL state, not an error. The web has viewer accounts, and
            // these routes use `requirePermission('admin.members')` — so a
            // READER gets a 403 by design. An empty list would say "this
            // farm has no members", which is a false statement about the
            // farm rather than a true one about the reader.
            //
            // The farm profile row is hidden with the rest, not shown and
            // then refused: its GET needs `admin.manage`, which is the same
            // OWNER/ADMIN pair, so a reader who gets here cannot open it.
            EmptyState(
                "Нямате достъп до този раздел",
                icon: "lock",
                message: "Управлението на достъпа е достъпно само за администратори на стопанството."
            )

        case .allowed:
            List {
                Section { farmRow }.pageRow()
                // The bottom-row editor, moved off every screen's toolbar
                // and into the one place that holds settings.
                Section { TabCustomiserRow() }.pageRow()
                Section { membersRow }.pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .pageBackground()
        }
    }

    /// The producer's name as the row's value: it says WHICH farm, and it is
    /// the one field that appears on public filings anyway. Never an
    /// identifier — the ЕИК, ЕГН and УРН stay one tap away, behind the page
    /// that knows how to show them.
    private var farmRow: some View {
        NavigationLink {
            FarmProfileView(store: store)
        } label: {
            LabeledContent {
                switch store.profile {
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Неуспешно зареждане")
                case .loaded(let profile, _):
                    Text(profile.isEmpty
                         ? "Непопълнено"
                         : (profile.producerName ?? ""))
                        .lineLimit(1)
                }
            } label: {
                Label("Стопанство", systemImage: "building.2")
            }
        }
    }

    /// The count is of the rows the page lists — invited and deactivated
    /// included — so tapping through never shows a different number of
    /// people than the row promised.
    private var membersRow: some View {
        NavigationLink {
            MembersView(store: store)
        } label: {
            LabeledContent {
                if let all = store.members.value {
                    Text("\(all.count)").monospacedDigit()
                } else if case .loading = store.members {
                    ProgressView()
                }
            } label: {
                Label("Потребители", systemImage: "person.2")
            }
        }
    }
}
