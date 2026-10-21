import MapKit
import SwiftUI

/// «Нова задача», step two (#388, owner 2026-10-21): the parcels the task is
/// for, chosen by block, on a map and in a list, as «Ново мероприятие»'s step
/// two chooses by crop.
///
/// OPTIONAL: «Създай» works with none chosen, for a task that isn't about a
/// field. A choice in one block stays when another block is opened, so a
/// task can cover fields in two blocks. The footer counts the ones out of
/// view.
struct NewTaskParcelsView: View {
    let store: TaskBlocksStore
    @Binding var blockID: String?
    @Binding var chosen: Set<String>
    let saving: Bool
    let failure: String?
    /// «Създай», or «Опитай пак» once the task exists and some parcels
    /// didn't attach (`NewTaskView`).
    let primaryTitle: String
    let onPrimary: () -> Void
    /// «Готово» beside it in that case: keep the task as it is.
    let onDone: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledMapHeight: CGFloat = 230
    @State private var camera: MapCameraPosition = .region(.bulgaria)

    private var blocks: [Location] { store.blocks.value ?? [] }
    private var block: Location? { blocks.first { $0.id == blockID } }
    private var fieldsState: LoadState<[TreatmentPlace.Field]>? { blockID.flatMap { store.fields[$0] } }
    private var fields: [TreatmentPlace.Field] { fieldsState?.value ?? [] }
    private var chosenHere: Int { fields.filter { chosen.contains($0.id) }.count }
    private var mapHeight: CGFloat { typeSize.isAccessibilitySize ? 140 : min(scaledMapHeight, 320) }

    var body: some View {
        VStack(spacing: 0) {
            if fields.contains(where: { $0.parcel.isDrawable }) {
                TreatmentParcelMap(fields: fields, outlines: store.outlines, chosen: chosen,
                                   camera: $camera, onToggle: toggle)
                    .frame(height: mapHeight)
            }
            list
        }
        .pageBackground()
        .safeAreaInset(edge: .bottom) { saveBar }
        .inlineTitle("Парцели")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { blockMenu }
        }
        .task(id: blockID) {
            if let block { await store.loadFields(for: block) }
        }
        .onChange(of: fields.map(\.id), initial: true) { _, _ in
            if !fields.isEmpty {
                camera = .region(MKCoordinateRegion(fitting: fields.map(\.parcel)) ?? .bulgaria)
            }
        }
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }
    }

    // MARK: - The block, top right

    private var blockMenu: some View {
        Menu {
            Picker("Блок", selection: $blockID) {
                ForEach(blocks) { Text($0.name).tag(String?.some($0.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            if typeSize.isAccessibilitySize {
                Label(block?.name ?? "Блок", systemImage: "map").labelStyle(.iconOnly)
            } else {
                Label(block?.name ?? "Блок", systemImage: "map").labelStyle(.titleAndIcon)
            }
        }
        .disabled(blocks.isEmpty)
        .accessibilityLabel("Блок")
        .accessibilityValue(block?.name ?? "не е избран")
        .accessibilityInputLabels(A11y.spokenNames("Блок", block?.name, "Block"))
        .accessibilityShowsLargeContentViewer {
            Label(block?.name ?? "Блок", systemImage: "map")
        }
    }

    // MARK: - The list

    private var list: some View {
        List {
            switch store.blocks {
            case .loading:
                Section { ProgressView().pageRow() }
            case .failed(let message):
                Section { retryRow(message) { await store.load() } }
            case .loaded where blocks.isEmpty:
                Section { note("Няма блокове. Задачата може да е и без парцели.").pageRow() }
            case .loaded:
                if let block {
                    blockSection(block)
                } else {
                    Section { note(Self.chooseBlock).pageRow() }
                }
            }
        }
        .pageBackground()
    }

    static let chooseBlock = "Изберете блок горе вдясно. Парцелите са по избор: задачата може да е и без тях."

    @ViewBuilder
    private func blockSection(_ block: Location) -> some View {
        switch fieldsState {
        case .loading, nil:
            Section { ProgressView().pageRow() } header: { SectionHeader(block.name) }
        case .failed(let message):
            Section {
                retryRow(message) { await store.loadFields(for: block) }
            } header: {
                SectionHeader(block.name)
            }
        case .loaded where fields.isEmpty:
            Section { note("В този блок няма парцели.").pageRow() } header: { SectionHeader(block.name) }
        case .loaded:
            Section {
                selectAllButton().cardRow()
                ForEach(fields) { row($0) }
            } header: {
                SectionHeader(block.name)
            } footer: {
                SectionFooter(footerText())
            }
        }
    }

    private func row(_ field: TreatmentPlace.Field) -> some View {
        let picked = chosen.contains(field.id)
        let area = field.parcel.areaHa.map { Area(hectares: $0) }
        let crop = CommodityName.freeText(field.parcel.cropType)
        return Button {
            toggle(field.id)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.parcel.name)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    MetaRow {
                        if let crop { Text(crop) }
                        if let area {
                            if crop != nil { MetaSeparator() }
                            Text(area.text)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 8)
                if picked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardRow()
        .accessibilityLabel(A11y.sentence([field.parcel.name, crop, area?.spoken]))
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityInputLabels([field.parcel.name])
    }

    private func selectAllButton() -> some View {
        let all = fields.allSatisfy { chosen.contains($0.id) }
        return Button {
            if all {
                chosen.subtract(fields.map(\.id))
            } else {
                chosen.formUnion(fields.map(\.id))
            }
        } label: {
            Label(all ? "Премахни избора" : "Избери всички (\(fields.count))",
                  systemImage: all ? "checklist.unchecked" : "checklist.checked")
        }
        .accessibilityInputLabels(all ? A11y.Spoken.deselectAll : A11y.Spoken.selectAll)
    }

    private func footerText() -> String {
        var lines = ["Избрани \(chosenHere) от \(Plural.bg(fields.count, "парцел", "парцела"))."]
        let elsewhere = chosen.count - chosenHere
        if elsewhere > 0 {
            lines.append("Още \(Plural.bg(elsewhere, "избран парцел", "избрани парцела")) в други блокове.")
        }
        let undrawn = fields.filter { !$0.parcel.isDrawable }.count
        if undrawn > 0 {
            lines.append(undrawn == 1
                ? "1 парцел няма очертание и се избира само от списъка."
                : "\(undrawn) парцела нямат очертание и се избират само от списъка.")
        }
        return lines.joined(separator: " ")
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    // MARK: - «Създай»

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(chosen.isEmpty
                     ? "Без парцели."
                     : "\(Plural.bg(chosen.count, "парцел", "парцела")) към задачата.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Button(action: onPrimary) {
                if saving {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Създаване")
                } else {
                    Text(primaryTitle).frame(maxWidth: .infinity)
                }
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(saving)
            .accessibilityInputLabels(primaryTitle == "Създай" ? A11y.Spoken.create : A11y.Spoken.retry)
            if let onDone {
                Button(action: onDone) {
                    Text("Готово, без тях").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(saving)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func retryRow(_ message: String, _ retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Опитай пак") { Task { await retry() } }
                .accessibilityInputLabels(A11y.Spoken.retry)
        }
        .pageRow()
    }
}
