import MapKit
import SwiftUI

struct ParcelMapView: View {
    let location: Location

    @State private var store: ParcelsStore

    /// Remembered per user, and PRECISE BY DEFAULT — the owner's call.
    ///
    /// Both modes are now imagery. Simplified draws each field as one
    /// rectangle, coloured sown or fallow, framed tight on the parcels;
    /// precise draws the true outlines with their holes, framed on the
    /// farm's own bounds, and carries the vegetation indices. The tileless
    /// schematic this replaced is gone, and with it the argument that the
    /// first frame needs no network — the stale banner above is what answers
    /// no signal now, and it answers it for every screen rather than for
    /// this one alone.
    ///
    /// A NEW KEY, deliberately, with the old one left unread. What
    /// `locations.useSchematicMap` recorded was an answer to "do you want
    /// the tileless, hand-coloured map?", and there is nothing honest to
    /// migrate that to: someone who chose the schematic was not choosing
    /// rectangles over outlines. Everyone starts from the owner's default
    /// and picks again.
    ///
    /// One button, two states. MapKit offers standard/hybrid/satellite for
    /// free and adding them would turn this into a picker, which is the one
    /// thing it was asked not to become.
    @AppStorage("locations.parcelMapSimplified") private var simplified = false

    @Environment(\.colorSchemeContrast) private var contrast

    /// The parcel whose operation sheet is open.
    @State private var operating: Parcel?

    /// Nil until resolved. The tap is offered meanwhile — see
    /// `CurrentUser.mayCreateOperations`, which fails open.
    @State private var me: CurrentUser?

    private var mayOperate: Bool { me?.mayCreateOperations ?? true }

    @State private var indices: SatelliteIndexStore

    /// The index whose explainer is open.
    @State private var explaining: VegetationIndex?

    /// The parcel the target button last jumped to, and the camera move that
    /// took it there. The tick is what makes a second press on the same
    /// parcel move again — see `SatelliteParcelMap.CameraCommand`.
    @State private var focusedID: String?
    @State private var cameraTick = 0
    @State private var camera: SatelliteParcelMap.CameraCommand?

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
        .inlineTitle(location.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleMode()
                } label: {
                    Label(
                        simplified ? "Точни граници" : "Опростена",
                        systemImage: simplified ? "pentagon" : "square.dashed"
                    )
                }
                .accessibilityHint(simplified
                    ? "Превключва към точните очертания на парцелите"
                    : "Превключва към опростена карта с правоъгълни парцели")
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
                if simplified && !drawable.isEmpty { legend }
                if !simplified && !drawable.isEmpty { indexControls }
                parcelList(response, drawable: drawable)
            }
        }
    }

    // MARK: - Map

    /// Only for the simplified view, where the fill colour is the only thing
    /// on screen saying which fields are sown. The precise view has the
    /// vegetation indices and their own legend, and paints every parcel
    /// alike, so a sown/fallow key there would explain a distinction it does
    /// not draw.
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
        } else {
            // ONE map view for both modes, differing by `shape`. Two views in
            // an if/else would give SwiftUI different structural identity,
            // tearing down the MKMapView and re-firing the index refresh on
            // every toggle.
            //
            // No index tiles under the rectangles. Earth Engine clips each
            // tile to the TRUE parcel shape, so beneath a box the colour
            // would stop at the field's real edge and the corners stay bare —
            // which reads as "the data ends here" rather than as a
            // simplification.
            SatelliteParcelMap(
                parcels: drawable,
                region: mapRegion(simplified: simplified),
                tileTemplate: simplified ? nil : indices.tiles?.tileUrl,
                shape: simplified ? .boundingBoxes : .outlines,
                contrast: contrast,
                camera: camera,
                onTap: mayOperate ? { operating = $0 } : nil
            )
            .overlay(alignment: .bottomTrailing) { targetButton(drawable) }
            .task { await indices.refreshIfNeeded() }
        }
    }

    /// Switch modes, and move the camera to match.
    ///
    /// THE CAMERA HAS TO BE TOLD. One map view serves both modes, so a
    /// toggle is not a rebuild, and `region` is read only when the view is
    /// first made — deliberately, since honouring it on every update would
    /// undo the farmer's zoom each time they tapped an index chip. Without
    /// this command the shapes would change under an unchanged camera and
    /// "zoomed in versus zoomed out" would not happen at all.
    ///
    /// A method rather than a closure in the toolbar so that the action can
    /// be invoked from somewhere other than the button — which is the only
    /// way this path gets exercised outside a human thumb.
    private func toggleMode() {
        simplified.toggle()
        cameraTick += 1
        camera = .init(tick: cameraTick, region: mapRegion(simplified: simplified))
    }

    /// Where each mode opens.
    ///
    /// PRECISE is unchanged: the server's bounds when it sent any, then the
    /// location's own, then the parcels, then Bulgaria. Both boxes are
    /// [minLon, minLat, …] and both are read through `BoundingBox`'s NAMED
    /// fields — never positionally, which is how a camera ends up in the Red
    /// Sea.
    ///
    /// SIMPLIFIED frames the parcels themselves, which is tighter than the
    /// farm's holding bounds by construction and needs no invented zoom
    /// number. Where a location has no server bounds the two are the same
    /// expression and the toggle will not appear to move the camera — that is
    /// honest rather than broken, since there is nothing else to frame.
    private func mapRegion(simplified: Bool) -> MKCoordinateRegion {
        let response = store.state.value
        let drawable = response?.parcels.filter(\.isDrawable) ?? []
        if simplified, let fitted = MKCoordinateRegion(fitting: drawable) {
            return fitted
        }
        return (response?.bounds ?? location.boundsJson)?.region
            ?? MKCoordinateRegion(fitting: drawable)
            ?? .bulgaria
    }

    // MARK: - Target

    /// Walks the fields, one press at a time — the web's «Намери моето поле».
    ///
    /// ON THE MAP, not in the toolbar. The trailing bar slot already holds
    /// the mode toggle, and the title beside it is a principal item put there
    /// because Bulgarian titles truncate when the bar mis-measures them; a
    /// second glyph would eat what is left of that budget. It is not in the
    /// control bar under the map either, because that bar does not render at
    /// all where Earth Engine is unconfigured, and this button has nothing to
    /// do with the indices.
    ///
    /// Bottom-trailing because bottom-leading is Apple's attribution, which
    /// must not be covered, and because that is where a thumb is.
    @ViewBuilder
    private func targetButton(_ drawable: [Parcel]) -> some View {
        Button {
            focusNext(drawable)
        } label: {
            Image(systemName: "dot.viewfinder")
                .font(.title3)
                .padding(11)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .padding(16)
        .accessibilityLabel(drawable.count == 1 ? "Центрирай парцела" : "Следващ парцел")
        .accessibilityHint("Центрира картата върху следващия парцел")
    }

    /// Camera only — no selection, no sheet — matching the web.
    ///
    /// Cycles the DRAWABLE parcels rather than all of them. A parcel with no
    /// outline is in the list and not on the map, so a press that framed it
    /// would move the camera to nothing.
    private func focusNext(_ drawable: [Parcel]) {
        guard let next = ParcelFocus.next(after: focusedID, in: drawable) else { return }
        // Advance the focus even when the camera cannot be built, which is
        // the web's behaviour and the right one: a parcel whose geometry is
        // degenerate would otherwise trap the button on itself forever, and
        // pressing again would keep failing on the same field.
        focusedID = next.id
        guard let region = MKCoordinateRegion(fitting: [next]) else { return }

        cameraTick += 1
        camera = .init(tick: cameraTick, region: region)

        // The camera move IS the effect, and MKMapView exposes none of it to
        // VoiceOver. Said in the same order and the same words as the
        // parcel's own row, so the two do not describe one field differently.
        AccessibilityNotification.Announcement(A11y.sentence([
            ParcelFocus.position(of: next, in: drawable),
            next.name,
            CommodityName.freeText(next.cropType),
            next.areaHa.map { "\(Num.text($0)) хектара" },
        ])).post()
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
    /// The date on the left, the explainer on the right, one row.
    ///
    /// The bulb is placed opposite the date rather than beside the legend
    /// because the two things a reader questions at this moment are "how
    /// old is this?" and "what am I looking at?" — so the answers to both
    /// sit on the same line, at either end of it.
    @ViewBuilder
    private var acquisition: some View {
        if let selected = indices.selected {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                acquisitionText
                Spacer(minLength: 8)
                Button {
                    explaining = selected
                } label: {
                    Image(systemName: "lightbulb")
                        .font(.footnote)
                        // The GLYPH is 13pt and the glyph is not the target.
                        // A `.plain` button is hit-tested against its label's
                        // bounds, so as drawn this was roughly 10×13pt of
                        // tappable area — on a screen reached in a field, by
                        // a thumb, often in a glove. The frame supplies the
                        // target and `contentShape` is what makes its empty
                        // part tappable at all; without it the transparent
                        // space around the bulb stays dead.
                        //
                        // 32 rather than 44 in height: 44 is the minimum for
                        // a control standing alone, and this one sits in a
                        // row whose height it would otherwise set, pushing
                        // the map up by that difference. The width carries
                        // the rest, and the row is at the bar's edge where
                        // nothing else competes for the touch.
                        //
                        // Trailing-aligned so the bulb stays exactly where it
                        // was drawn — flush with the bar's edge, under the
                        // "Висока" end of the ramp. A centred frame would
                        // push it 16pt inward and break that column for a
                        // change nobody asked for; the target grows inward,
                        // where there is nothing to hit by mistake.
                        .frame(width: 44, height: 32, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .accessibilityLabel("Какво означава \(selected.name)")
                .accessibilityHint("Отваря обяснение на индекса")
            }
        }
    }

    @ViewBuilder
    private var acquisitionText: some View {
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
