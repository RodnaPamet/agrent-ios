import SwiftUI

/// A machine by its id, from an alert push (#574): «it left the farm's
/// area». Reads the farm's machines and opens that one's day. The alert goes
/// to OWNER and ADMIN only, who may read the list; anyone else, or a machine
/// gone since, is said in words.
struct MachineLinkView: View {
    let assetID: String
    @State private var state: LoadState<Machine?> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorState(message: message) { await load() }
            case .loaded(let machine, _):
                if let machine {
                    MachineDayView(day: MachineDay(machine: machine))
                } else {
                    ContentUnavailableView("Машината не е намерена", systemImage: "location.slash",
                                           description: Text("Може тракерът ѝ вече да е премахнат."))
                }
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            let machines = try await MachinesAPI.machines()
            state = .loaded(machines.first { $0.assetId == assetID }, .fresh)
        } catch {
            state = .failed(UserMessage.text(for: error))
        }
    }
}
