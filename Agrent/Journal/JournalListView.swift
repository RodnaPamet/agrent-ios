import SwiftUI

struct JournalListView: View {
    @Environment(AuthClient.self) private var auth
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                content
                newEntryButton
            }
            .navigationTitle("Земеделски дневник")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Изход") { auth.signOut() }
                }
            }
            .sheet(isPresented: $composing) {
                NewEntryView(store: store)
            }
            .task { if store.state.value == nil { await store.load() } }
        }
    }

    /// The primary action is a full-width target at the bottom of the screen,
    /// not a toolbar glyph. A gloved thumb reaches the bottom of a phone; the
    /// top-right corner is the hardest place on the device to hit one-handed,
    /// and this is the action an operator performs standing in a field.
    @ViewBuilder
    private var newEntryButton: some View {
        if store.state.value != nil {
            Button {
                composing = true
            } label: {
                Text("Нов запис").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.bar)
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

        case .loaded(let entries, _) where entries.isEmpty:
            ContentUnavailableView(
                "Няма записи",
                systemImage: "book.closed",
                description: Text("Добавете първия запис в дневника.")
            )

        case .loaded(let entries, _):
            List {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            JournalDetailView(entry: entry)
                        } label: {
                            JournalRow(entry: entry)
                        }
                    }
                } header: {
                    Text("^[\(entries.count) записа](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }
}

/// One diary entry.
///
/// Sized for the actual reading conditions: outdoors, in sunlight, at arm's
/// length, with Dynamic Type possibly turned well up. The previous version
/// set the title at `.subheadline` and everything else at `.caption` — the
/// design review counted `.footnote` used ten times across the app and
/// `.body` not once, which is a desk application's type scale on a tool meant
/// to be used standing in a field.
///
/// So: `.headline` title, `.subheadline` supporting text, and the type as a
/// CHIP rather than one more grey word in a run of grey words — at a glance a
/// regulated input application is now distinguishable from an observation
/// without reading either.
struct JournalRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                CategoryChip(
                    text: entry.type.label,
                    foreground: entry.type.chipColors.foreground,
                    background: entry.type.chipColors.background
                )
                Text(entry.occurredAt, format: .dateTime.day().month(.wide))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if entry.status == .planned {
                    Text("·").foregroundStyle(.secondary)
                    Text(entry.status.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
