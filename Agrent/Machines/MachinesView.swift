import MapKit
import SwiftUI

/// «Машини» (#574, owner 2026-11-09): where the farm's machines are, for
/// OWNER and ADMIN. A map of every machine that has reported, a list with
/// each one's state and when it was last heard from, and the trackers the
/// machines carry. A machine opens its day: route and worked parcels.
///
/// Opened from the menu, in a stack of its own: not a tab, as the web has no
/// page for it yet and a bottom bar holds only the web's own pages.
struct MachinesView: View {
    @State private var store = MachinesStore()
    @State private var camera: MapCameraPosition = .automatic
    @State private var adding = false
    @State private var removing: TrackerRegister.Tracker?
    @State private var confirmingRemoval = false
    @State private var removeFailure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Машини")
                .navigationDestination(for: MachineDay.self) { MachineDayView(day: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                    if store.registerAvailable {
                        ScreenAction(title: "Нов тракер", spoken: A11y.Spoken.newTracker) { adding = true }
                    }
                }
                .task { await store.load() }
                .task { await store.poll() }
                .sheet(isPresented: $adding) {
                    AddTrackerSheet(register: store.register) { Task { await store.load() } }
                }
                .confirmationDialog("Премахване на тракера?", isPresented: $confirmingRemoval, titleVisibility: .visible,
                                    presenting: removing) { tracker in
                    Button("Премахни", role: .destructive) { Task { await remove(tracker) } }
                        .accessibilityInputLabels(A11y.Spoken.remove)
                    Button("Отказ", role: .cancel) {}
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                } message: { tracker in
                    Text("\(tracker.assetName ?? "Машината") спира да се проследява. Маршрутите ѝ остават до 30 дни.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.machines {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded(let machines, _):
            List {
                if machines.contains(where: { $0.positionSource?.isSimulated == true }) {
                    Section {
                        Label(MachineWords.demoNotice, systemImage: "theatermasks")
                            .font(.subheadline)
                            .foregroundStyle(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .pageRow()
                }
                Section {
                    if placed(machines).isEmpty {
                        Text(machines.isEmpty
                             ? "Още няма проследявани машини. Добавете GPS тракер с «+» или свържете телематиката на производителя от уеб приложението."
                             : "Машините още не са подали местоположение.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                    } else {
                        map(machines)
                            .frame(height: 280)
                            .listRowInsets(EdgeInsets())
                    }
                }
                .pageRow()
                if !machines.isEmpty {
                    Section {
                        ForEach(machines) { machine in
                            NavigationLink(value: MachineDay(machine: machine)) { row(machine) }
                        }
                    } header: {
                        SectionHeader("Машини")
                    }
                    .pageRow()
                }
                trackersSection
            }
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    private func placed(_ machines: [Machine]) -> [Machine] { machines.filter { $0.lastPosition != nil } }

    private func map(_ machines: [Machine]) -> some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(placed(machines)) { machine in
                if let position = machine.lastPosition {
                    Annotation(machine.name, coordinate: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)) {
                        MachinePin(moving: position.moving == true)
                    }
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        // The list below says the same, a row per machine, in words.
        .accessibilityHidden(true)
    }

    private func row(_ machine: Machine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(machine.name).font(.body.weight(.semibold))
            Text(MachineWords.row(machine))
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trackersSection: some View {
        if let register = store.register, !register.trackers.isEmpty {
            Section {
                ForEach(register.trackers) { tracker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.assetName ?? "Машина").font(.body)
                        Text(trackerLine(tracker))
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Премахни", role: .destructive) {
                            removing = tracker
                            confirmingRemoval = true
                        }
                            .accessibilityInputLabels(A11y.Spoken.remove)
                    }
                }
            } header: {
                SectionHeader("Тракери")
            } footer: {
                SectionFooter {
                    if let removeFailure {
                        Text(removeFailure).foregroundStyle(Palette.error)
                    }
                }
            }
            .pageRow()
        } else if let failure = store.registerFailure {
            Section { Text(failure).font(.footnote).foregroundStyle(Palette.secondaryText) }.pageRow()
        }
    }

    /// «IMEI 350424060000000, сигнал 14:31»; who confirmed the drivers were told.
    private func trackerLine(_ tracker: TrackerRegister.Tracker) -> String {
        var parts = ["IMEI \(tracker.imei)"]
        if let label = tracker.label, !label.isEmpty { parts.append(label) }
        parts.append(tracker.lastSeenAt.map { "сигнал \(BgDate.messageTime($0))" } ?? "без сигнал")
        if let by = tracker.driversInformedByName {
            parts.append("шофьорите уведомени от \(by)")
        }
        return parts.joined(separator: ", ")
    }

    private func remove(_ tracker: TrackerRegister.Tracker) async {
        removeFailure = nil
        do { try await store.remove(tracker) } catch { removeFailure = UserMessage.text(for: error) }
        removing = nil
    }
}

/// A machine on the map: green while it moves, grey when it stands.
struct MachinePin: View {
    let moving: Bool

    var body: some View {
        Image(systemName: moving ? "location.north.circle.fill" : "stop.circle.fill")
            .font(.title2)
            .foregroundStyle(moving ? Palette.success : Palette.secondaryText)
            .background(Circle().fill(Palette.Surface.card))
    }
}

/// A machine's day, pushed by value onto «Машини»'s own stack.
struct MachineDay: Hashable {
    let machine: Machine

    func hash(into hasher: inout Hasher) { hasher.combine(machine.assetId) }
    static func == (lhs: MachineDay, rhs: MachineDay) -> Bool { lhs.machine.assetId == rhs.machine.assetId }
}
