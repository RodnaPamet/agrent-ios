import SwiftUI

struct JournalListView: View {
    @Environment(AuthClient.self) private var auth
    @State private var store = JournalStore()
    @State private var composing = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    ProgressView("Зареждане…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Неуспешно зареждане", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Опитай пак") { Task { await store.load() } }
                    }
                case .loaded where store.entries.isEmpty:
                    ContentUnavailableView(
                        "Няма записи",
                        systemImage: "book.closed",
                        description: Text("Добавете първия запис в дневника.")
                    )
                case .loaded:
                    List(store.entries) { entry in
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
            .task { if store.phase == .idle { await store.load() } }
        }
    }
}
