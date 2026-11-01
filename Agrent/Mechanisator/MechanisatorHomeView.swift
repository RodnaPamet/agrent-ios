import MapKit
import SwiftUI

/// A MECHANISATOR's whole app (#465, owner 2026-10-29): the farm's map with
/// a number on each parcel that has the person's own current tasks, and
/// those tasks under it. A parcel opens its screen: risk, its tasks, its
/// history.
///
/// ── Instead of the tabs ──
///
/// The owner chose one screen over Блокове and Задачи as tabs: an operator
/// has one job, the work on the farm's fields, and it fits one place. The
/// menu keeps Риск and Админ (Профил, Изход). Every other role keeps its
/// tabs; `MainTabView` decides.
///
/// ── The whole farm, assigned to me ──
///
/// Every block's parcels on one map, fitted to the farm (owner: not one
/// block at a time). The list and the numbers are the person's own current
/// tasks (`GET /farm-tasks`, whose default is "assigned to me"); a parcel's
/// screen still shows all of its tasks.
///
/// ── The parcels, as a list too ──
///
/// Under the tasks, every parcel with its count. A map is not a way in for
/// VoiceOver, Voice Control or Switch Control, and a field too small to hit
/// at the farm's zoom is one row away here.
struct MechanisatorHomeView: View {
    /// The one stack the router keeps for this screen: every route, a
    /// notification's task included, opens on it.
    static let surface = AppSurface.tasks

    var body: some View {
        RoutedStack {
            MechanisatorHome()
        }
    }
}

private struct MechanisatorHome: View {
    @State private var parcels = FarmParcelsStore()
    @State private var tasks = MyTasksStore()
    @State private var counts = TaskParcelCounts()
    @State private var choosing: ParcelChoice?
    /// The phone's dot, and «Моето местоположение»'s camera moves (#492).
    @State private var location = DeviceLocation.shared
    @State private var cameraTick = 0
    @State private var camera: SatelliteParcelMap.CameraCommand?
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            map
                .containerRelativeFrame(.vertical) { height, _ in height * 0.42 }
            list
        }
        .background(Palette.Surface.page)
        .navigationTitle("Моите задачи")
        .navigationBarTitleDisplayMode(.inline)
        .appMenu()
        .sheet(item: $choosing) { choice in
            ParcelChooser(parcels: choice.parcels) { picked in
                choosing = nil
                // One sheet gone before the next screen is asked for, as on
                // a block's map.
                DispatchQueue.main.async { open(picked) }
            }
        }
        .task { if parcels.blocks.value == nil { await parcels.load() } }
        .task { if tasks.state.value == nil { await tasks.load() } }
        // The counts follow the current tasks: a task closed or newly given,
        // or a row now carrying its parcels, changes the numbers.
        .task(id: tasks.current ?? []) { await counts.load(tasks.current ?? []) }
    }

    // MARK: - The map

    @ViewBuilder
    private var map: some View {
        let drawable = parcels.all.map(\.parcel).filter(\.isDrawable)
        switch parcels.blocks {
        case .failed(let message):
            mapNote(message, retry: true)
        case .loaded where !parcels.settled, .loading:
            ProgressView("Зареждане на картата…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if drawable.isEmpty {
                mapNote("Няма парцели с очертания за картата.", retry: false)
            } else {
                // Built once every block has answered, as the camera fits
                // the farm only when the map opens (`SatelliteParcelMap`).
                SatelliteParcelMap(
                    parcels: drawable,
                    region: MKCoordinateRegion(fitting: drawable) ?? .bulgaria,
                    tileTemplate: nil,
                    contrast: contrast,
                    camera: camera,
                    onTap: { tapped($0) },
                    badges: counts.counts,
                    showsDeviceLocation: location.access == .allowed
                )
                // The map is a picture to VoiceOver; the parcels list under
                // the tasks is its way in.
                .accessibilityLabel("Карта на стопанството")
                // Where the mechanisator stands on the farm (#492): the dot,
                // the parcel it is in by name, and the button that asks and
                // then centres.
                .overlay(alignment: .bottomTrailing) {
                    MapLocationButton { coordinate in
                        cameraTick += 1
                        camera = .init(tick: cameraTick, region: .around(coordinate))
                    }
                    .padding(.bottom, 16)
                }
                .overlay(alignment: .topLeading) { StandingInLabel(parcels: drawable) }
                .showsDeviceLocation()
            }
        }
    }

    private func mapNote(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Button("Опитай пак") { Task { await parcels.load() } }
                    .accessibilityInputLabels(A11y.Spoken.retry)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One parcel under the finger opens it; several, where shapes cross,
    /// ask which, as on a block's map.
    private func tapped(_ hit: [Parcel]) {
        if hit.count == 1 {
            open(hit[0])
        } else if hit.count > 1 {
            choosing = ParcelChoice(parcels: hit)
        }
    }

    private func open(_ parcel: Parcel) {
        guard let place = parcels.all.first(where: { $0.parcel.id == parcel.id }) else { return }
        pushRoute(route(place))
    }

    /// The parcel's screen as Блокове opens it: in its block, so it has its
    /// risk, its tasks, and «Ново мероприятие» for whoever may record.
    private func route(_ place: ParcelInBlock) -> AppRoute {
        .parcelHistory(parcelID: place.parcel.id, parcelName: place.parcel.name, recordIn: place)
    }

    // MARK: - The list

    private var list: some View {
        List {
            Group {
                taskRows
                parcelRows
            }
            .pageRow()
        }
        .listStyle(.plain)
        .pageBackground()
        .refreshable {
            await PullToRefresh.bounded {
                await tasks.load()
                await parcels.load()
            }
        }
    }

    @ViewBuilder
    private var taskRows: some View {
        switch tasks.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Опитай пак") { Task { await tasks.load() } }
                    .accessibilityInputLabels(A11y.Spoken.retry)
            }
            .listRowSeparator(.hidden)
        case .loaded:
            let current = tasks.current ?? []
            if current.isEmpty {
                Text("Нямате възложени задачи.")
                    .font(.body)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            } else {
                Section(titled: Plural.bg(current.count, "задача", "задачи")) {
                    ForEach(current) { item in
                        NavigationLink(value: AppRoute.task(item)) {
                            TaskRow(item: item, showsAssignee: false)
                        }
                        .pageRow()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var parcelRows: some View {
        let places = MechanisatorParcels.ordered(parcels.all, counts: counts.counts)
        if !places.isEmpty {
            Section(titled: "Парцели") {
                ForEach(places, id: \.parcel.id) { place in
                    NavigationLink(value: route(place)) {
                        parcelRow(place, count: counts.counts[place.parcel.id] ?? 0)
                    }
                    .pageRow()
                }
            }
        }
    }

    private func parcelRow(_ place: ParcelInBlock, count: Int) -> some View {
        let tasksText = count > 0 ? Plural.bg(count, "задача", "задачи") : nil
        return HStack(alignment: .firstTextBaseline) {
            Text(place.parcel.name)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let tasksText {
                Text(tasksText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([place.parcel.name, tasksText]))
    }
}

/// The order of the parcels list, kept out of the view so it can be tested.
enum MechanisatorParcels {
    /// The parcels with the person's tasks first, most tasks first, then
    /// every other parcel; by name within each, as a farmer looks for one.
    static func ordered(_ places: [ParcelInBlock], counts: [String: Int]) -> [ParcelInBlock] {
        places.sorted { a, b in
            let ca = counts[a.parcel.id] ?? 0, cb = counts[b.parcel.id] ?? 0
            if ca != cb { return ca > cb }
            return a.parcel.name.localizedStandardCompare(b.parcel.name) == .orderedAscending
        }
    }
}
