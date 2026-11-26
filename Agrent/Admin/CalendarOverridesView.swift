import SwiftUI

/// «Календар: поправки» (agri-saas#3095, owner 2026-11-16): the agronomic
/// calendar's corrections and additions, for every farm. The platform farm's
/// owner or admins only, as «Цени» — and the server checks again.
struct CalendarOverridesView: View {
    @State private var store = CalendarOverridesStore()
    @State private var picking = false
    @State private var editing: CalendarOverrideTarget?
    @State private var confirmingClear: CalendarOverridesAPI.Override?

    var body: some View {
        List {
            Section {
                Text(CalendarOverridesText.intro)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pageRow()
            if let failure = store.failure {
                Section { Text(failure).foregroundStyle(Palette.error) }.pageRow()
            }
            switch store.overrides {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 80).pageRow()
            case .failed(let message):
                ErrorState(message: message) { await store.load() }.pageRow()
            case .loaded(let rows, _):
                if rows.isEmpty {
                    Section { Text(CalendarOverridesText.empty).foregroundStyle(Palette.secondaryText) }.pageRow()
                } else {
                    Section {
                        ForEach(rows) { row in
                            Button { editing = .override(row) } label: { OverrideRow(row: row, cropTitle: store.cropTitle(row.cropKey)) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { confirmingClear = row } label: {
                                        Label(CalendarOverridesText.remove, systemImage: "arrow.uturn.backward")
                                    }
                                    .accessibilityInputLabels(A11y.spokenNames(CalendarOverridesText.remove, "Remove"))
                                }
                                .pageRow()
                        }
                    } header: {
                        SectionHeader(CalendarOverridesText.liveTitle)
                    }
                }
            }
        }
        .pageBackground()
        .inlineTitle(CalendarOverridesText.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { picking = true } label: { Label(CalendarOverridesText.new, systemImage: "plus") }
                    .disabled(store.crops.isEmpty)
                    .accessibilityInputLabels(A11y.spokenNames(CalendarOverridesText.new, "New"))
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $picking) {
            CalendarWindowPicker(store: store) { target in
                picking = false
                // One sheet after the other: the first must be gone first.
                DispatchQueue.main.async { editing = target }
            }
        }
        .sheet(item: $editing) { target in
            CalendarOverrideEditor(target: target, cropTitle: store.cropTitle(target.cropKey)) {
                await store.load()
            }
        }
        .confirmationDialog(CalendarOverridesText.removeQuestion, isPresented: Binding(
            get: { confirmingClear != nil }, set: { if !$0 { confirmingClear = nil } }
        ), titleVisibility: .visible, presenting: confirmingClear) { row in
            Button(CalendarOverridesText.remove, role: .destructive) { Task { await store.clear(row) } }
        } message: { row in
            Text(row.isAddition ? CalendarOverridesText.removeAddition : CalendarOverridesText.removeCorrection)
        }
    }
}

/// One live override: the crop, which window, its dates, and the basis.
private struct OverrideRow: View {
    let row: CalendarOverridesAPI.Override
    let cropTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cropTitle).font(.body.weight(.medium))
            MetaRow {
                Text(row.isAddition ? CalendarOverridesText.added : CalendarOverridesText.corrected)
                MetaSeparator()
                Text(CalendarOverridesText.kind(row.window.kind, band: row.window.band))
                if let span = AgroWords.span(row.window.from, row.window.to) {
                    MetaSeparator()
                    Text(span)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            Text(row.basis.bg)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(CalendarOverridesText.editHint)
    }
}

/// What the editor opens on: an existing override, a cited window to correct,
/// or a new window for a crop.
enum CalendarOverrideTarget: Identifiable, Hashable {
    case override(CalendarOverridesAPI.Override)
    case correct(cropKey: String, window: CalendarOverridesAPI.WindowDraft)
    case add(cropKey: String)

    var id: String {
        switch self {
        case .override(let o): "override:\(o.windowId)"
        case .correct(_, let w): "correct:\(w.id)"
        case .add(let crop): "add:\(crop)"
        }
    }

    var cropKey: String {
        switch self {
        case .override(let o): o.cropKey
        case .correct(let crop, _), .add(let crop): crop
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Crop, then window — or «Нов срок» for one МЗХ does not publish.
private struct CalendarWindowPicker: View {
    let store: CalendarOverridesStore
    let picked: (CalendarOverrideTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.crops) { crop in
                NavigationLink(crop.title) { windows(of: crop) }
                    .pageRow()
            }
            .pageBackground()
            .inlineTitle(CalendarOverridesText.pickCrop)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
            }
        }
    }

    private func windows(of crop: AgroCalendar.Crop) -> some View {
        List {
            Section {
                Button { picked(.add(cropKey: crop.key)) } label: {
                    Label(CalendarOverridesText.addWindow, systemImage: "plus.circle")
                }
                .pageRow()
            }
            Section {
                ForEach(store.windowsByCrop[crop.key] ?? []) { w in
                    Button { picked(.correct(cropKey: crop.key, window: .init(w))) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CalendarOverridesText.kind(w.kind.rawValue, band: w.band))
                            MetaRow {
                                Text(CalendarOverridesText.region(w.region))
                                if let span = AgroWords.span(w.from, w.to) { MetaSeparator(); Text(span) }
                            }
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .pageRow()
                }
            } header: {
                SectionHeader(CalendarOverridesText.correctWindow)
            }
        }
        .pageBackground()
        .inlineTitle(crop.title)
    }
}
