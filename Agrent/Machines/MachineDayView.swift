import MapKit
import SwiftUI

/// One machine's day (#574): its route on the map for a day within the last
/// 30, and the parcels it worked, which the server keeps for good. Today's
/// worked parcels are worked out overnight, so they show tomorrow.
struct MachineDayView: View {
    let day: MachineDay

    @State private var store: MachineDayStore
    /// The farm's day, not the phone's (agri-saas #3013: the server has one
    /// definition of a farm day, Europe/Sofia, for the route and the worked
    /// parcels alike).
    private static let farm = FarmRecordAPI.farmCalendar
    @State private var date = MachineDayView.farm.startOfDay(for: Date())
    @State private var camera: MapCameraPosition = .automatic
    /// «Нов запис» from the worked parcels (owner, 2026-11-09): a draft for
    /// the person to check, never a ДНЕВНИК entry by itself.
    @State private var recording: WorkedRecord?
    @State private var people = CurrentUserStore.shared

    init(day: MachineDay) {
        self.day = day
        _store = State(initialValue: MachineDayStore(assetID: day.machine.assetId))
    }

    private var dayText: String { BgDate.isoDay(date, in: Self.farm) }
    private var isToday: Bool { Self.farm.isDateInToday(date) }

    var body: some View {
        List {
            Section {
                DatePicker("Ден", selection: $date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
                    // Days as the farm counts them, so the picked day is the
                    // one asked for.
                    .environment(\.calendar, Self.farm)
                    .environment(\.timeZone, Self.farm.timeZone)
                Text(MachineWords.status(day.machine.lastPosition, source: day.machine.positionSource, hasSourceField: true))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .pageRow()
            routeSection
            workedSection
        }
        .pageBackground()
        .inlineTitle(day.machine.name)
        .sheet(item: $recording) { record in
            TreatmentEntryFlow(recorder: LiveTreatmentRecorder(), prefill: TreatmentDraft(date: record.day),
                               preselect: record.parcels) {}
        }
        .task(id: dayText) {
            camera = .automatic
            await store.load(day: dayText)
        }
    }

    @ViewBuilder
    private var routeSection: some View {
        Section {
            switch store.track {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Palette.secondaryText)
            case .loaded(let track, _):
                if !track.points.isEmpty {
                    route(track)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                }
                if let note = MachineWords.trackNote(track) {
                    Text(note).font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            }
        } header: {
            SectionHeader("Маршрут")
        }
        .pageRow()
    }

    private func route(_ track: MachineTrack) -> some View {
        let line = track.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return Map(position: $camera, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: line)
                .stroke(Palette.accent, lineWidth: 4)
            if let first = line.first {
                Annotation("Начало", coordinate: first) {
                    Image(systemName: "circle.fill").foregroundStyle(Palette.success)
                }
            }
            if let last = line.last, line.count > 1 {
                Annotation("Край", coordinate: last) {
                    Image(systemName: "flag.checkered.circle.fill").font(.title3).foregroundStyle(Palette.accent)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        // The parcels it worked are said below, in words.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var workedSection: some View {
        Section {
            switch store.worked {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Palette.secondaryText)
            case .loaded(let worked, _):
                ForEach(worked.parcels) { parcel in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parcel.name).font(.body)
                        Text(MachineWords.worked(parcel))
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = MachineWords.workedNote(worked, isToday: isToday) {
                    Text(note).font(.footnote).foregroundStyle(Palette.secondaryText)
                }
                if !worked.parcels.isEmpty, people.user?.mayWrite ?? true {
                    Button {
                        recording = WorkedRecord(day: date, parcels: MachineWords.preselected(worked))
                    } label: {
                        Label("Нов запис от тези парцели", systemImage: "square.and.pencil")
                    }
                    .accessibilityInputLabels(A11y.spokenNames("Нов запис от тези парцели", "Нов запис", "New entry"))
                }
            }
        } header: {
            SectionHeader("Обработени парцели")
        } footer: {
            SectionFooter("Изчислени от маршрута. Не се записват в дневника сами: «Нов запис» ги предлага, вие проверявате и добавяте.")
        }
        .pageRow()
    }
}

/// The day and parcels a «Нов запис» starts from.
struct WorkedRecord: Identifiable {
    let id = UUID()
    let day: Date
    let parcels: Set<String>
}
