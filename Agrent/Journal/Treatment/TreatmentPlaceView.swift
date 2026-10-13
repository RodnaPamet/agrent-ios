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
/// «Запази» carries the total, so the area being recorded is in view at the
/// moment it is recorded — and so does a refusal, above the button it
/// refused.
struct TreatmentPlaceView: View {
    let store: TreatmentPlaceStore
    let kind: TreatmentDraft.Kind
    @Binding var cropKey: String?
    @Binding var chosen: Set<String>
    let saving: Bool
    let failure: String?
    let onSave: ([TreatmentPlace.Field]) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledMapHeight: CGFloat = 230
    @State private var camera: MapCameraPosition = .region(.bulgaria)

    private var crops: [TreatmentPlace.Crop] { store.state.value ?? [] }
    private var crop: TreatmentPlace.Crop? { crops.first { $0.key == cropKey } }
    private var chosenFields: [TreatmentPlace.Field] { crop?.fields.filter { chosen.contains($0.id) } ?? [] }
    private var total: TreatmentPlace.Total { TreatmentPlace.total(chosenFields) }
    private var areaWord: String { kind == .spray ? "Третирана площ" : "Наторена площ" }

    /// Above the list, never at the cost of it: the map grows with the text
    /// only to a cap, and at the accessibility sizes it is small — the list,
    /// which is the accessible way to choose, is what must keep its room.
    private var mapHeight: CGFloat { typeSize.isAccessibilitySize ? 140 : min(scaledMapHeight, 320) }

    var body: some View {
        VStack(spacing: 0) {
            if let crop, crop.fields.contains(where: { $0.parcel.isDrawable }) {
                TreatmentParcelMap(crop: crop, outlines: store.outlines, chosen: chosen,
                                   camera: $camera, onToggle: toggle)
                    .frame(height: mapHeight)
            }
            list
        }
        .pageBackground()
        .safeAreaInset(edge: .bottom) { saveBar }
        .inlineTitle("Къде")
        // A save under way is not abandoned by a swipe back, and its refusal
        // does not land on a screen that has gone.
        .navigationBarBackButtonHidden(saving)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { cropMenu }
        }
        .onChange(of: cropKey, initial: true) { _, _ in
            // The parcels of the crop that was, are not this crop's.
            chosen = chosen.filter { id in crop?.fields.contains { $0.id == id } == true }
            if let crop { camera = .region(MKCoordinateRegion(fitting: crop.fields.map(\.parcel)) ?? .bulgaria) }
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
                ForEach(crops) { Text($0.label).tag(String?.some($0.key)) }
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
                Section { note(message).pageRow() }
            case .loaded where crops.isEmpty:
                Section { note(Self.noCrops).pageRow() }
            case .loaded:
                if let crop {
                    Section {
                        // The whole crop, first: a spray of «всичко с
                        // пшеница» is one tap, not one per field.
                        selectAllButton(crop).cardRow()
                        ForEach(crop.fields) { field in row(field) }
                    } header: {
                        SectionHeader(crop.label)
                    } footer: {
                        SectionFooter(footerText(crop))
                    }
                } else {
                    Section { note(Self.chooseCrop).pageRow() }
                }
            }
        }
        .pageBackground()
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

    private func selectAllButton(_ crop: TreatmentPlace.Crop) -> some View {
        let all = crop.fields.allSatisfy { chosen.contains($0.id) }
        return Button {
            if all {
                chosen.subtract(crop.fields.map(\.id))
            } else {
                chosen.formUnion(crop.fields.map(\.id))
            }
        } label: {
            Label(all ? "Премахни избора" : "Избери всички (\(crop.fields.count))",
                  systemImage: all ? "checklist.unchecked" : "checklist.checked")
        }
        .accessibilityInputLabels(all ? A11y.Spoken.deselectAll : A11y.Spoken.selectAll)
    }

    /// How many are chosen — what the map shows, said where everyone gets it —
    /// and what the list or the total does not include.
    private func footerText(_ crop: TreatmentPlace.Crop) -> String {
        var lines = ["Избрани \(chosenFields.count) от \(Plural.bg(crop.fields.count, "парцел", "парцела"))."]
        let undrawn = crop.fields.filter { !$0.parcel.isDrawable }.count
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
        if store.unreadBlocks > 0 {
            lines.append("Парцелите на " + Plural.bg(store.unreadBlocks, "блок", "блока")
                         + " не можаха да се заредят и липсват от списъка.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - «Запази»

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
                onSave(chosenFields)
            } label: {
                if saving {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Записване")
                } else {
                    Text("Запази").frame(maxWidth: .infinity)
                }
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(saving || chosenFields.isEmpty)
            .accessibilityHint(chosenFields.isEmpty ? "Изберете поне един парцел." : "")
            .accessibilityInputLabels(A11y.Spoken.save)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
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
