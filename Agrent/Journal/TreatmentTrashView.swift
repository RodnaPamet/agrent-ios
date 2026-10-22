import SwiftUI

/// «Кошче» (#395): the treatments removed from this farm's Дневник, newest
/// first, each with «Възстанови».
///
/// A restore brings back everything a reader saw, on the list and in the
/// printed ДНЕВНИК, because the server only cleared the soft-delete
/// (agri-saas #2184). It is offered to anyone who may write. The server
/// lets the treatment's creator and an administrator do it, and its
/// refusal is shown under the row.
struct TreatmentTrashView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[TreatmentTrashAPI.Deleted]> = .loading
    @State private var restoring: String?
    @State private var refusals: [String: String] = [:]
    @State private var people = CurrentUserStore.shared

    private let load: @MainActor () async throws -> [TreatmentTrashAPI.Deleted]
    private let restore: @MainActor (String) async throws -> Void
    /// The journal list is read again, and the handle is no longer hidden.
    let onRestored: (String) -> Void

    init(load: @escaping @MainActor () async throws -> [TreatmentTrashAPI.Deleted] = { try await TreatmentTrashAPI.list() },
         restore: @escaping @MainActor (String) async throws -> Void = { try await TreatmentTrashAPI.restore($0) },
         onRestored: @escaping (String) -> Void) {
        self.load = load
        self.restore = restore
        self.onRestored = onRestored
    }

    var body: some View {
        NavigationStack {
            content
                .background(Palette.Surface.page)
                .navigationTitle("Кошче")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { await read() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await read() }
        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Кошчето е празно",
                icon: "trash",
                message: "Изтритите мероприятия се показват тук и могат да бъдат възстановени."
            )
        case .loaded(let rows, _):
            List {
                Section(titled: Plural.bg(rows.count, "изтрито мероприятие", "изтрити мероприятия")) {
                    ForEach(rows) { row in
                        TrashRow(row: row, mayRestore: people.user?.mayWrite ?? true,
                                 restoring: restoring == row.id, refusal: refusals[row.id]) {
                            Task { await put(back: row) }
                        }
                        .pageRow()
                    }
                }
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await read() } }
        }
    }

    private func read() async {
        do {
            state = .loaded(try await load(), .fresh)
        } catch {
            // The rows on screen stay, as the journal keeps its own: a
            // refresh that fails says nothing about what was listed.
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
        }
    }

    /// Gone from «Кошче» once the server takes it back, or once it says
    /// nothing withdrawn is left under the handle: restored elsewhere.
    private func put(back row: TreatmentTrashAPI.Deleted) async {
        guard restoring == nil else { return }
        restoring = row.id
        refusals[row.id] = nil
        defer { restoring = nil }
        do {
            try await restore(row.id)
        } catch let error where TreatmentTrashAPI.isNotWithdrawn(error) {
            // Already back.
        } catch {
            refusals[row.id] = UserMessage.text(for: error)
            return
        }
        if case .loaded(let rows, let freshness) = state {
            state = .loaded(rows.filter { $0.id != row.id }, freshness)
        }
        AccessibilityNotification.Announcement(TrashRow.restoredText(row)).post()
        onRestored(row.id)
    }
}

/// One withdrawn treatment: what it was, when it was done, when it went.
struct TrashRow: View {
    let row: TreatmentTrashAPI.Deleted
    let mayRestore: Bool
    let restoring: Bool
    let refusal: String?
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title(row))
                .font(.headline)
                .foregroundStyle(.primary)
            Text(Self.lines(row).joined(separator: "\n"))
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if mayRestore {
                Button(action: onRestore) {
                    if restoring {
                        ProgressView()
                    } else {
                        Text("Възстанови")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(restoring)
                .accessibilityLabel("Възстанови")
                .accessibilityInputLabels(A11y.Spoken.restore)
            }
            if let refusal {
                Text(refusal)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// The product, else the kind of work, else the one word that is true
    /// of every row here. A server that lists only the handle and the dates
    /// (#2184 as first written) still gets a row a person can act on.
    nonisolated static func title(_ row: TreatmentTrashAPI.Deleted) -> String {
        if let product = row.productName?.recorded { return product }
        if let kind = row.kind.flatMap(TreatmentDraft.Kind.init(rawValue:)) { return kind.label }
        return "Мероприятие"
    }

    /// When the work was done and where, then when it was removed.
    nonisolated static func lines(_ row: TreatmentTrashAPI.Deleted) -> [String] {
        var lines: [String] = []
        var done: [String] = []
        if let day = row.occurredOn.flatMap(BgDate.parseISODay) { done.append(BgDate.full(day)) }
        if let parcels = row.parcelCount, parcels > 0 { done.append(Plural.bg(parcels, "парцел", "парцела")) }
        if !done.isEmpty { lines.append(done.joined(separator: ", ")) }
        if !row.blockNames.isEmpty { lines.append(row.blockNames.joined(separator: ", ")) }
        if let at = row.deletedAt { lines.append("Изтрито на \(BgDate.full(at))") }
        return lines
    }

    nonisolated static func restoredText(_ row: TreatmentTrashAPI.Deleted) -> String {
        "Възстановено: \(title(row))"
    }
}
