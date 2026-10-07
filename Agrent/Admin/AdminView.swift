import SwiftUI

/// Админ: the farm, the app, the people — and, last, what the phone resolved.
///
/// Reached from the app menu rather than a tab: five tab slots exist before
/// iOS collapses the rest into "More", and this is a monthly action while
/// Задачи is a daily one. Operator frequency decides the tab bar.
///
/// ── FOUR ROWS, IN THE OWNER'S ORDER (2026-10-01, 2026-10-02) ──
///
///     (account card) → Профил, and on it Изход (2026-10-04, 2026-10-07)
///     «Стопанство»   → the farm profile, which can now be edited
///     «Долна лента»  → the bottom-bar editor
///     «Потребители»  → the members, with their count
///     «Диагностика»  → the resolved feature flags, read-only
///
/// «Диагностика» goes BELOW the members because it is the owner's
/// measuring instrument, not farm administration, and it is hidden with the
/// rest on `.forbidden`: a reader has no business with the flag cohort, and
/// this screen is the admin gate it is behind. See `DiagnosticsView`.
///
/// This screen used to BE the member list, with the farm's identity block
/// under it. Each now has its own page (`FarmProfileView`, `MembersView`) and
/// this one is the index. The farm comes first because it is what the
/// administration is OF; the members are the longest page and go last.
///
/// ── The account card goes ABOVE «Стопанство» (owner, 2026-10-04) ──
///
/// It answers "as whom am I administering this farm" before anything below
/// is changed under that name. Since P2.8 (2026-10-06) it is a row that opens
/// Профил, and since 2026-10-07 the ONLY one: the owner took «Профил» and
/// «Изход» out of the app menu, so this row is every role's way to both.
/// That is why it is drawn in every state — see `accountRow`.
///
/// One store for all three. The rows show a member count and the producer's
/// name, so they read the same data the pages do — and a deactivation on the
/// members page is reflected in the count on the way back.
struct AdminView: View {
    @State private var store = AdminStore()
    /// The shared instance, held as `@State` the way `ConversationView` does,
    /// so the card redraws when `/me` resolves while Админ is open.
    @State private var me = CurrentUserStore.shared
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

    private var content: some View {
        List {
            // FIRST, and outside the switch: every state draws it.
            Section { accountRow }.pageRow()

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
                forbiddenNotice.pageRow()

            case .allowed:
                Section { farmRow }.pageRow()
                // The bottom-row editor, moved off every screen's toolbar
                // and into the one place that holds settings.
                Section { TabCustomiserRow() }.pageRow()
                Section { membersRow }.pageRow()
                Section { diagnosticsRow }.pageRow()
            }
        }
        .refreshable { await PullToRefresh.bounded { await store.load() } }
        .pageBackground()
    }

    /// Профил — and, on it, the app's only Изход. Since the owner took both
    /// out of the menu (2026-10-07) this row is the one way to either, for
    /// every role, so it is drawn in EVERY state:
    ///
    /// - On `.forbidden` too, above the notice. Профил is for every role
    ///   (P2.8), and a reader whom Админ refuses must still be able to leave.
    /// - Before `/me` has answered, and when it never does: a plain «Профил»
    ///   row, rather than nothing and rather than a blank circle with no
    ///   name. An offline launch with no cached `/me` is exactly when someone
    ///   might want Изход, and `ProfileView` draws it either way.
    ///
    /// The card is the component Профил draws — one card, not two copies that
    /// drift. Pushed, not a second sheet: Админ already is one, and its stack
    /// gives the back button.
    private var accountRow: some View {
        NavigationLink {
            ProfileView()
        } label: {
            if let user = me.user {
                AccountCard(user: user)
            } else {
                Label("Профил", systemImage: "person.crop.circle")
            }
        }
        // The card is a sentence about WHO, so the hint says WHERE the row
        // goes — nothing else on it does.
        .accessibilityHint("Отваря профила")
        // «Профил», which is where it leads, and the name, which is what is
        // printed on the card and what a Voice Control user reads off it.
        .accessibilityInputLabels(A11y.Spoken.profile + A11y.spokenNames(me.user?.name))
    }

    /// What a reader sees under the account row. A screen-filling
    /// `EmptyState` while it was the only thing on the page; under a row, it
    /// is a row and a footer, which wrap at every text size. A
    /// `ContentUnavailableView` row was tried and kept its title to one line:
    /// «Нямате достъп до то…» at the DEFAULT size (A11yShots, 2026-10-07).
    private var forbiddenNotice: some View {
        Section {
            Label("Нямате достъп до този раздел", systemImage: "lock")
        } footer: {
            SectionFooter("Управлението на достъпа е достъпно само за администратори на стопанството.")
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
            ValueRow {
                switch store.profile {
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Неуспешно зареждане")
                        .rowValue()
                case .loaded(let profile, _):
                    Text(profile.isEmpty
                         ? "Непопълнено"
                         : (profile.producerName ?? ""))
                        .rowValue()
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
            ValueRow {
                if let all = store.members.value {
                    Text("\(all.count)").monospacedDigit().rowValue()
                } else if case .loading = store.members {
                    ProgressView()
                }
            } label: {
                Label("Потребители", systemImage: "person.2")
            }
        }
    }

    /// No value on the row: a flag count would invite reading it as "how much
    /// is on", and the page is one tap away. The hint says what is behind it,
    /// because «Диагностика» alone does not.
    private var diagnosticsRow: some View {
        NavigationLink {
            DiagnosticsView()
        } label: {
            Label("Диагностика", systemImage: "stethoscope")
        }
        .accessibilityHint("Показва флаговете на функциите, получени от сървъра")
        .accessibilityInputLabels(A11y.spokenNames("Диагностика", "Diagnostics"))
    }
}

private extension Text {
    /// A row's VALUE — the producer's name on «Стопанство», the count on
    /// «Потребители».
    ///
    /// WRAPS, never truncates (#150). The name was `lineLimit(1)`, and at
    /// the accessibility sizes `LabeledContent` stacks the value under its
    /// label, where one line of AX5 text held «Синтети…» of the farm's name.
    /// The row's whole job is to say WHICH farm, and a cut name does not.
    ///
    /// The colour is no longer set here: `ValueRow` gives every row value
    /// `Palette.ListChrome.value` (#159), which is what this did for these
    /// two rows alone.
    func rowValue() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}
