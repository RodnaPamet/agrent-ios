import MapKit
import Observation
import SwiftUI

/// «Машини» on a task (#574): the machines the work uses, and where the
/// machine was last heard from, so the mechanisator on the task can find it
/// (owner, 2026-11-09: a MECHANISATOR sees only the machine on their own
/// current task). OWNER and ADMIN add a machine or take one off.
///
/// Both reads are under `farm-tasks`, the one prefix a mechanisator reaches
/// (agri-saas #2948). The position read answers 404 for a task that is not
/// the reader's; that is the same as no machine here, and says nothing.
@MainActor
@Observable
final class TaskMachinesStore {
    private(set) var linked: [MachineAsset]?
    private(set) var found: TaskMachine?
    private(set) var failure: String?
    private let taskID: String

    init(taskID: String) { self.taskID = taskID }

    func load() async {
        do {
            let data = try await APIClient.shared.data(for: MachinesAPI.taskAssetsPath(taskID))
            linked = try await MachinesAPI.decodeAssets(data)
            failure = nil
        } catch {
            if linked == nil { failure = UserMessage.text(for: error) }
        }
        found = (linked?.isEmpty ?? true) ? nil : try? await MachinesAPI.taskMachine(taskID)
    }

    func link(_ assetID: String) async throws {
        _ = try await APIClient.shared.postReturningData(
            MachinesAPI.taskAssetsPath(taskID), body: ["assetId": assetID], idempotencyKey: UUID().uuidString)
        await load()
    }

    func unlink(_ assetID: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(MachinesAPI.taskAssetPath(taskID, assetID: assetID))
        await load()
    }
}

struct TaskMachinesSection: View {
    let store: TaskMachinesStore
    /// OWNER or ADMIN, on the server's word: they choose the machines.
    let mayManage: Bool

    @State private var farmMachines: [MachineAsset] = []
    @State private var removing: MachineAsset?
    @State private var confirmingRemoval = false
    @State private var changeFailure: String?

    var body: some View {
        if let failure = store.failure {
            section { Text(failure).font(.footnote).foregroundStyle(Palette.error) }
        } else if let linked = store.linked, !linked.isEmpty || mayManage {
            section {
                ForEach(linked) { machine in
                    HStack {
                        Text([machine.name, MachineKind.label(machine.type),
                              machine.sourceKnown && machine.positionSource == nil ? "без източник на местоположение" : machine.positionSource?.label].compactMap { $0 }.joined(separator: ", "))
                            .font(.body)
                        Spacer(minLength: 8)
                        if mayManage {
                            Button("Махни") {
                                removing = machine
                                confirmingRemoval = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Palette.destructive)
                            .accessibilityLabel("Махни \(machine.name) от задачата")
                            .accessibilityInputLabels(A11y.Spoken.remove)
                        }
                    }
                }
                if let found = store.found, let position = found.lastPosition {
                    lastSeen(position, of: found)
                }
                if mayManage {
                    addMenu(linked)
                }
                if let changeFailure {
                    Text(changeFailure).font(.footnote).foregroundStyle(Palette.error)
                }
            }
            .task(id: mayManage) {
                guard mayManage else { return }
                farmMachines = ((try? await MachinesAPI.assets()) ?? []).filter(\.isMachine)
            }
            .confirmationDialog("Да се махне ли машината от задачата?", isPresented: $confirmingRemoval,
                                titleVisibility: .visible, presenting: removing) { machine in
                Button("Махни", role: .destructive) { Task { await change { try await store.unlink(machine.id) } } }
                    .accessibilityInputLabels(A11y.Spoken.remove)
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
        }
    }

    private func lastSeen(_ position: Machine.Position, of found: TaskMachine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(MachineWords.taskMachine(found, position), systemImage: "location.north.circle")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Map(initialPosition: .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon),
                distance: 1500))) {
                Annotation("Машината", coordinate: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)) {
                    MachinePin(moving: position.moving == true)
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Said in the line above, in words.
            .accessibilityHidden(true)
        }
    }

    private func addMenu(_ linked: [MachineAsset]) -> some View {
        let open = farmMachines.filter { machine in !linked.contains { $0.id == machine.id } }
        return Menu {
            ForEach(open) { machine in
                Button(machine.name) { Task { await change { try await store.link(machine.id) } } }
            }
        } label: {
            Label("Добави машина", systemImage: "plus")
                .font(.subheadline.weight(.medium))
        }
        .disabled(open.isEmpty)
        .accessibilityInputLabels(A11y.spokenNames("Добави машина", "Машина", "Add machine"))
    }

    private func change(_ body: () async throws -> Void) async {
        changeFailure = nil
        do { try await body() } catch { changeFailure = UserMessage.text(for: error) }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Машини")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
