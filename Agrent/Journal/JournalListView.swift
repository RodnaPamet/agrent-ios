import SwiftUI

struct JournalListView: View {
    @Environment(AuthClient.self) private var auth
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Above the switch on purpose: an EMPTY list can be stale too,
                // and "no entries" from a week-old cache means something very
                // different from "no entries" off a live fetch.
                if let age = store.state.freshness?.ageDescription {
                    StaleBanner(age: age)
                }
                content
            }
            .navigationTitle("Земеделски дневник")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        composing = true
                    } label: {
                        Label("Нов запис", systemImage: "plus")
                    }
                }
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

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Неуспешно зареждане", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Опитай пак") { Task { await store.load() } }
            }

        case .loaded(let entries, _) where entries.isEmpty:
            ContentUnavailableView(
                "Няма записи",
                systemImage: "book.closed",
                description: Text("Добавете първия запис в дневника.")
            )

        case .loaded(let entries, _):
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.headline)
                    HStack(spacing: 8) {
                        Text(entry.type.label)
                        Text("·")
                        Text(entry.occurredAt, format: .dateTime.day().month().year())
                        if entry.status == .planned {
                            Text("·"); Text(entry.status.label)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .refreshable { await store.load() }
        }
    }
}
