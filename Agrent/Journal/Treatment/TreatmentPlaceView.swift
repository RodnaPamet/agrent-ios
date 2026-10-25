import MapKit
import SwiftUI

/// «Ново мероприятие», step two: which crop, and which of its parcels
/// (agrent-ios#293).
///
/// The crop is chosen at the top right, as the owner described it. Its
/// parcels across the farm's blocks then appear twice: on a map, where a tap
/// on a field toggles it, and in a list, where every parcel can be chosen by
/// name. The LIST is the control that always works — for VoiceOver, Voice
/// Control and a keyboard, and for a parcel with no outline to tap. The map
/// is the second way, for the person who knows their fields by shape, and
/// gives way to the list at the accessibility text sizes.
///
/// «Продължи» carries the total, so the area being recorded is in view at
/// the moment it is chosen — and so does a problem, above the button it
/// stopped. The save itself is step three's (`TreatmentCheckView`, #362).
struct TreatmentPlaceView: View {
    let store: TreatmentPlaceStore
    let kind: TreatmentDraft.Kind
    /// Other work (#439): its area is plain «Площ», as it treats nothing.
    var activity: ActivityKind? = nil
    @Binding var cropKey: String?
    @Binding var chosen: Set<String>
    /// The treated area typed per chosen parcel, in decares (#363).
    @Binding var treatedText: [String: String]
    let failure: String?
    /// Reads the crop list again after it failed. The flow's, not the
    /// store's, because the flow also chooses a farm's only crop.
    let retryCrops: @MainActor () async -> Void
    let onContinue: ([TreatmentPlace.Field]) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledMapHeight: CGFloat = 230
    @State private var camera: MapCameraPosition = .region(.bulgaria)

    private var crops: [TreatmentPlace.Crop] { store.state.value ?? [] }
    private var crop: TreatmentPlace.Crop? { crops.first { $0.key == cropKey } }
    /// The chosen crop's parcels, as far as they are loaded.
    private var fieldsState: LoadState<[TreatmentPlace.Field]>? { cropKey.flatMap { store.fields[$0] } }
    private var fields: [TreatmentPlace.Field] { fieldsState?.value ?? [] }
    private var chosenFields: [TreatmentPlace.Field] { fields.filter { chosen.contains($0.id) } }
    private var total: TreatmentPlace.Total {
        TreatmentPlace.total(chosenFields,
                             treated: TreatmentDraft.treatedAreas(treatedText, for: chosenFields).mapValues(\.wireHectares))
    }
    private var areaWord: String {
        if activity != nil { return "Площ" }
        return kind.areaWord
    }

    /// Above the list, never at the cost of it: the map grows with the text
    /// only to a cap, and at the accessibility sizes it is small — the list,
    /// which is the accessible way to choose, is what must keep its room.
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
        .inlineTitle("Къде")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { cropMenu }
        }
        // The crop's parcels, asked for as it is chosen — and again on a
        // return, which a cache-first read makes cheap.
        .task(id: cropKey) {
            if let crop { await store.loadFields(for: crop) }
        }
        .onChange(of: cropKey) { _, _ in
            // The parcels of the crop that was, are not this crop's. Not on
            // the first appearance: coming back from step one keeps the
            // choice.
            chosen = []
        }
        .onChange(of: fields.map(\.id), initial: true) { _, _ in
            if !fields.isEmpty {
                camera = .region(MKCoordinateRegion(fitting: fields.map(\.parcel)) ?? .bulgaria)
            }
        }
        // Said, not only drawn: the refusal replaces the spinner under the
        // cursor, and on a long crop it would otherwise be heard by nobody.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            var line = AttributedString(now)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }

    // MARK: - The crop, top right

    private var cropMenu: some View {
        Menu {
            Picker("Култура", selection: $cropKey) {
                ForEach(crops) { crop in
                    Text("\(crop.label) (\(crop.parcelCount))").tag(String?.some(crop.key))
                }
            }
            .pickerStyle(.inline)
        } label: {
            // The name in the bar at the usual sizes; the leaf alone at the
            // accessibility sizes, where the list's header says the crop at
            // full size and a long name in the bar would only be cut.
            if typeSize.isAccessibilitySize {
                Label(crop?.label ?? "Култура", systemImage: "leaf").labelStyle(.iconOnly)
            } else {
                Label(crop?.label ?? "Култура", systemImage: "leaf").labelStyle(.titleAndIcon)
            }
        }
        .disabled(crops.isEmpty)
        .accessibilityLabel("Култура")
        .accessibilityValue(crop?.label ?? "не е избрана")
        .accessibilityInputLabels(A11y.spokenNames("Култура", crop?.label, "Crop"))
        .accessibilityShowsLargeContentViewer {
            Label(crop?.label ?? "Култура", systemImage: "leaf")
        }
    }

    // MARK: - The list

    private var list: some View {
        List {
            switch store.state {
            case .loading:
                Section { ProgressView().pageRow() }
            case .failed(let message):
                // Without a retry, a crop list that failed — offline, with
                // nothing cached — could only be left by cancelling the entry
                // and losing step one.
                Section { retryRow(message) { await retryCrops() } }
            case .loaded where crops.isEmpty:
                Section { note(Self.noCrops).pageRow() }
            case .loaded:
                if let crop {
                    cropSection(crop)
                    treatedSection
                } else {
                    Section { note(Self.chooseCrop).pageRow() }
                }
            }
        }
        .pageBackground()
    }

    @ViewBuilder
    private func cropSection(_ crop: TreatmentPlace.Crop) -> some View {
        switch fieldsState {
        case .loading, nil:
            Section { ProgressView().pageRow() } header: { SectionHeader(crop.label) }
        case .failed(let message):
            Section {
                retryRow(message) { await store.loadFields(for: crop) }
            } header: {
                SectionHeader(crop.label)
            }
        case .loaded:
            Section {
                // The whole crop, first: a spray of «всичко с пшеница» is one
                // tap, not one per field.
                selectAllButton().cardRow()
                ForEach(fields) { field in row(field) }
            } header: {
                SectionHeader(crop.label)
            } footer: {
                SectionFooter(footerText())
            }
        }
    }

    private func row(_ field: TreatmentPlace.Field) -> some View {
        let picked = chosen.contains(field.id)
        let area = field.parcel.areaHa.map { Area(hectares: $0) }
        return Button {
            toggle(field.id)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.parcel.name)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    MetaRow {
                        Text(field.blockName)
                        if let area { MetaSeparator(); Text(area.text) }
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
        .accessibilityLabel(A11y.sentence([field.parcel.name, field.blockName, area?.spoken]))
        .accessibilityAddTraits(picked ? .isSelected : [])
        // The name on the row is what Voice Control should answer to; two
        // blocks with a field of the same name fall back to numbering.
        .accessibilityInputLabels([field.parcel.name, "\(field.parcel.name) \(field.blockName)"])
    }

    /// Each chosen parcel's treated area (#363, owner 2026-10-20): its whole
    /// area unless one is typed, which is how the ДНЕВНИК prints a row per
    /// parcel. Below the list rather than in it, so choosing stays one tap
    /// a row and a long crop doesn't double in length.
    @ViewBuilder
    private var treatedSection: some View {
        if !chosenFields.isEmpty {
            Section {
                ForEach(chosenFields) { field in
                    let whole = field.parcel.areaHa.map { Area(hectares: $0) }
                    FieldRow(field.parcel.name,
                             spoken: "\(areaWord) на \(field.parcel.name) в декари") {
                        TextField("дка", text: $treatedText[typed: field.id],
                                  prompt: .fieldPrompt(whole?.number ?? "дка"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    .cardRow()
                }
            } header: {
                SectionHeader("\(areaWord), дка")
            } footer: {
                SectionFooter(Self.treatedNote)
            }
        }
    }

    static let treatedNote = "Празно поле означава целия парцел. Въведете по-малка площ, ако е третирана само част от него."

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

    /// How many are chosen — what the map shows, said where everyone gets it —
    /// and what the list or the total does not include.
    private func footerText() -> String {
        var lines = ["Избрани \(chosenFields.count) от \(Plural.bg(fields.count, "парцел", "парцела"))."]
        let undrawn = fields.filter { !$0.parcel.isDrawable }.count
        if undrawn > 0 {
            lines.append(undrawn == 1
                ? "1 парцел няма очертание и се избира само от списъка."
                : "\(undrawn) парцела нямат очертание и се избират само от списъка.")
        }
        if total.withoutArea > 0 {
            lines.append(total.withoutArea == 1
                ? "1 избран парцел е без площ и не е включен в площта."
                : "\(total.withoutArea) избрани парцела са без площ и не са включени в площта.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - «Продължи»

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if total.parcels > 0 {
                Text("\(areaWord): \(total.area.text) — \(Plural.bg(total.parcels, "парцел", "парцела")).")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // «дка» spelled out, as everywhere an area is spoken.
                    .accessibilityLabel("\(areaWord): \(total.area.spoken), "
                                        + Plural.bg(total.parcels, "парцел", "парцела") + ".")
            }
            Button {
                onContinue(chosenFields)
            } label: {
                Text("Продължи").frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(chosenFields.isEmpty)
            .accessibilityHint(chosenFields.isEmpty ? "Изберете поне един парцел." : "")
            .accessibilityInputLabels(A11y.Spoken.proceed)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func retryRow(_ message: String, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            note(message)
            Button("Опитайте отново") { Task { await retry() } }
                .font(.footnote)
        }
        .pageRow()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let chooseCrop = "Изберете културата горе вдясно — ще се покажат всички нейни парцели."
    private static let noCrops =
        "Никой парцел на стопанството няма култура. Задайте културата на парцелите от картата им."
}
