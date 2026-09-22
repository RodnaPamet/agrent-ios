import MapKit
import SwiftUI

struct ParcelMapView: View {
    let location: Location

    @State private var store: ParcelsStore

    /// Remembered per user, and SCHEMATIC BY DEFAULT.
    ///
    /// The default is the decision, not the toggle. Schematic's first frame
    /// needs no network, so a farmer opening this with no coverage sees their
    /// fields rather than grey tiles — and that is the situation this screen
    /// exists for. MapKit is the deliberate second look, for geographic
    /// context, which is when imagery is genuinely what you want. Neither is
    /// a fallback for the other.
    ///
    /// One button, two states. MapKit offers standard/hybrid/satellite for
    /// free and adding them would turn this into a picker, which is the one
    /// thing it was asked not to become.
    @AppStorage("locations.useSchematicMap") private var useSchematic = true

    @Environment(\.colorSchemeContrast) private var contrast

    /// The parcel whose operation sheet is open.
    @State private var operating: Parcel?

    /// Nil until resolved. The tap is offered meanwhile — see
    /// `CurrentUser.mayCreateOperations`, which fails open.
    @State private var me: CurrentUser?

    private var mayOperate: Bool { me?.mayCreateOperations ?? true }

    @State private var indices: SatelliteIndexStore

    init(location: Location) {
        self.location = location
        _store = State(initialValue: ParcelsStore(locationID: location.id))
        _indices = State(initialValue: SatelliteIndexStore(locationID: location.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let age = store.state.freshness?.ageDescription {
                StaleBanner(age: age)
            }
            content
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    useSchematic.toggle()
                } label: {
                    Label(
                        useSchematic ? "Сателит" : "Схема",
                        systemImage: useSchematic ? "globe.europe.africa" : "square.on.square.dashed"
                    )
                }
                .accessibilityHint(useSchematic
                    ? "Превключва към сателитна карта"
                    : "Превключва към схематична карта")
            }
        }
        .sheet(item: $operating) { parcel in
            ParcelOperationSheet(
                locationID: location.id, parcel: parcel
            ) {
                Task { await store.load() }
            }
        }
        .task {
            if store.state.value == nil { await store.load() }
            me = await CurrentUserStore.shared.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let response, _):
            let drawable = response.parcels.filter(\.isDrawable)
            VStack(spacing: 0) {
                map(response, drawable: drawable)
                    .frame(maxHeight: .infinity)
                if useSchematic && !drawable.isEmpty { legend }
                if !useSchematic && !drawable.isEmpty { indexControls }
                parcelList(response, drawable: drawable)
            }
        }
    }

    // MARK: - Map

    /// Only for the schematic view. On satellite the fills sit over imagery
    /// and the colours are not the only cue, but here they carry the whole
    /// meaning, so the key has to be on screen.
    private var legend: some View {
        HStack(spacing: 16) {
            swatch(Palette.Map.sownFill, "Засят", dashed: false)
            swatch(Palette.Map.fallowFill, "Угар", dashed: true)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        // The swatches ARE the content here; spoken, they are two unlabelled
        // rectangles followed by two words. Said once, as what the key means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Легенда: плътно зелено е засят парцел, пунктирано светло е угар.")
    }

    /// The key must track the map. A legend showing a 0.85 tint beside a map
    /// drawing a near-solid fill is a key to a different picture, and it is
    /// exactly the person relying on the key who would be misled.
    private func swatch(_ color: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(contrast == .increased ? 0.95 : 0.85))
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            dashed ? Palette.Map.fallowStroke : Palette.Map.sownStroke,
                            style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : [])
                        )
                )
            Text(label).font(.footnote).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func map(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        if drawable.isEmpty {
            EmptyState(
                "Няма очертания",
                icon: "map",
                message: "Парцелите съществуват, но нямат географски очертания."
            )
        } else if useSchematic, let box = response.bounds ?? location.boundsJson {
            SchematicParcelMap(
                parcels: drawable, bounds: box,
                onTap: mayOperate ? { operating = $0 } : nil
            )
        } else {
            // Camera from `bounds` when the server sent one, otherwise from
            // the location's own boundsJson. Both are [minLon, minLat, …] and
            // both are read through BoundingBox's NAMED fields — never
            // positionally, which is how the camera ends up in the Red Sea.
            // One MKPolygon per GeoJSON polygon, holes already carried as
            // interiorPolygons — see ParcelGeometry.mapPolygons.
            SatelliteParcelMap(
                parcels: drawable,
                region: (response.bounds ?? location.boundsJson)?.region
                    ?? MKCoordinateRegion(fitting: drawable)
                    ?? .bulgaria,
                tileTemplate: indices.tiles?.tileUrl
            )
            .task { await indices.refreshIfNeeded() }
        }
    }

    // MARK: - Vegetation indices

    /// The index picker and, when one is drawn, its legend and date.
    ///
    /// Hidden entirely when `isConfigured` is nil or false — a deployment
    /// without Earth Engine has no imagery to offer, and a disabled button is
    /// a promise this screen cannot keep.
    @ViewBuilder
    private var indexControls: some View {
        if indices.isConfigured != false {
            VStack(alignment: .leading, spacing: 10) {
                indexPicker
                if let selected = indices.selected {
                    if indices.isLoading && indices.tiles == nil {
                        ProgressView().controlSize(.small)
                    } else if let failure = indices.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if indices.tiles != nil {
                        legendRamp(selected)
                        acquisition
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    /// A scrolling row rather than a `Picker`.
    ///
    /// Six options — off plus five indices — is two too many for a segmented
    /// control at any text size, and the first thing a segmented control does
    /// when it runs out of room is truncate the labels. NDVI and NDMI
    /// truncate to the same three letters.
    private var indexPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                indexChip(nil, label: "Без слой")
                ForEach(VegetationIndex.allCases) { index in
                    indexChip(index, label: index.name)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        // The row is one VoiceOver container of buttons; without this the
        // horizontal scroll view is announced as a separate stop first.
        .accessibilityLabel("Растителни индекси")
    }

    private func indexChip(_ index: VegetationIndex?, label: String) -> some View {
        let isSelected = indices.selected == index
        return Button {
            Task { await indices.select(index) }
        } label: {
            Text(label)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemFill),
                            in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(index.map(\.explanation) ?? "Показва само сателитната снимка")
    }

    /// The colour ramp, with the ends named.
    ///
    /// The gradient is the web's five stops in the web's order, so the same
    /// colour means the same number on both clients. A farmer comparing a
    /// phone in the field against a laptop at home is the reason that has to
    /// hold exactly.
    private func legendRamp(_ index: VegetationIndex) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(index.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LinearGradient(colors: index.ramp, startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Ends on one line is the one place here two items share a line,
            // and they can: each is a single short word pinned to its own
            // edge, so neither can grow into the other.
            HStack {
                Text(index.lowLabel)
                Spacer()
                Text(index.highLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index.name). \(index.explanation). "
            + "Скала от \(index.lowLabel.lowercased()) до \(index.highLabel.lowercased())")
    }

    /// WHEN THE PICTURE WAS TAKEN, and how long ago.
    ///
    /// The server composites the 30 days ending on the date asked for, and
    /// reaches further back when cloud masking leaves nothing usable — the
    /// first call this app ever made asked for today and got imagery from
    /// three days earlier, with nothing in the response marking it as old.
    ///
    /// So both the date and the age are printed. The date alone is a fact a
    /// person has to do arithmetic on; the age is the part that decides
    /// whether this canopy is worth spraying against. A false-colour field
    /// with no date is a picture that will be read as current, and that is
    /// the failure this screen would cause rather than prevent.
    @ViewBuilder
    private var acquisition: some View {
        if let date = indices.acquisitionDate {
            let days = Calendar.current.dateComponents(
                [.day], from: Calendar.current.startOfDay(for: date),
                to: Calendar.current.startOfDay(for: Date())).day ?? 0
            HStack(spacing: 5) {
                Image(systemName: "camera.badge.clock")
                Text(days <= 0
                    ? "Заснето днес"
                    : "Заснето на \(BgDate.dayMonth(date)) · преди \(Plural.bg(days, "ден", "дни"))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            // Never `.secondary`. This is the caveat on everything above it,
            // and the one line here that must not read as a footnote.
            .foregroundStyle(days > 10 ? Color.orange : Color.primary)
        } else {
            // The server may omit the date. Saying so is the honest answer —
            // an undated overlay must not be allowed to pass as a dated one.
            Text("Датата на заснемане е неизвестна.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Parcels

    @ViewBuilder
    private func parcelRow(_ parcel: Parcel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(parcel.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let crop = CommodityName.freeText(parcel.cropType) { Text(crop) }
                    if let area = parcel.areaHa {
                        if parcel.cropType != nil { Text("·") }
                        Text("\(Num.text(area)) ха")
                    }
                    if parcel.hasActiveLease == true {
                        Text("·"); Text("под аренда")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !parcel.isDrawable {
                // Says WHY it is absent from the map. A parcel silently
                // missing reads as lost data — but an outline the server
                // never had is not a fault, so it is stated, not warned
                // about.
                Label("без очертание", systemImage: "questionmark.square.dashed")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        // Up to three `·` separators in one row, so this was the worst of
        // them: "Пшеница middle dot 12,4 ха middle dot под аренда". Spoken
        // from the values, with the units said in full — "ха" is read as a
        // word, not as "хектара".
        .contentShape(Rectangle())
        .onTapGesture { if mayOperate { operating = parcel } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(mayOperate ? .isButton : [])
        .accessibilityHint(mayOperate ? "Двоен допир, за да запишете операция" : "")
        .accessibilityLabel(A11y.sentence([
            parcel.name,
            CommodityName.freeText(parcel.cropType),
            parcel.areaHa.map { "\(Num.text($0)) хектара" },
            parcel.hasActiveLease == true ? "под аренда" : nil,
            // The icon carried this and only as an icon label. It belongs in
            // the row's sentence: a parcel absent from the map is the thing
            // an operator most needs told, and it is invisible in a list.
            parcel.isDrawable ? nil : "без географско очертание",
        ]))
    }

    @ViewBuilder
    private func parcelList(_ response: ParcelsResponse, drawable: [Parcel]) -> some View {
        List {
            Section(header: Text(Plural.bg(response.parcels.count, "парцел", "парцела"))) {
                ForEach(response.parcels) { parcel in
                    parcelRow(parcel)
                }
            }
            if drawable.count != response.parcels.count {
                RefusalNote(
                    text: "\(response.parcels.count - drawable.count) парцела без очертания не се показват на картата.",
                    icon: "map"
                )
            }
        }
        .frame(maxHeight: 260)
    }
}
