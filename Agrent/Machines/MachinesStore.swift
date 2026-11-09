import Foundation
import Observation

/// The farm's machines and its tracker register, for «Машини» (#574).
///
/// Read live and never cached on disk: a machine's position is where its
/// driver is, which this app treats as it treats messages (`ResponseCache`
/// never holds it). Polled while the screen is open, as the server does not
/// stream positions in its first version (agri-saas #2948 §9).
@MainActor
@Observable
final class MachinesStore {
    private(set) var machines: LoadState<[Machine]> = .loading
    private(set) var register: TrackerRegister?
    /// Why the register could not be read, when it could not. The map
    /// stands without it.
    private(set) var registerFailure: String?
    /// False while the server has no tracker register yet (a 404: agri-saas
    /// #2948 ships the reads before the register). Then the screen offers no
    /// register and no «Нов тракер», rather than an error and a form that
    /// cannot save.
    private(set) var registerAvailable = true

    /// A tracker reports every 30 seconds or so; a minute between reads is
    /// fresh enough for "where is the tractor" and kind to a rural signal.
    static let refresh: Duration = .seconds(60)

    func load() async {
        do {
            machines = .loaded(try await MachinesAPI.machines(), .fresh)
        } catch {
            if machines.value == nil { machines = .failed(UserMessage.text(for: error)) }
        }
        do {
            register = try await MachinesAPI.trackers()
            registerFailure = nil
            registerAvailable = true
        } catch {
            if Self.isAbsent(error) {
                registerAvailable = false
                registerFailure = nil
            } else {
                registerFailure = UserMessage.text(for: error)
            }
        }
    }

    nonisolated static func isAbsent(_ error: Error) -> Bool {
        if case APIClient.APIError.http(let status, _, _, _, _) = error { return status == 404 }
        return false
    }

    /// Reads again every `refresh` until the task is cancelled (the screen
    /// went away).
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refresh)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    func remove(_ tracker: TrackerRegister.Tracker) async throws {
        try await MachinesAPI.removeTracker(tracker.id)
        await load()
    }
}

/// A machine's day: its route and the parcels it worked.
@MainActor
@Observable
final class MachineDayStore {
    private(set) var track: LoadState<MachineTrack> = .loading
    private(set) var worked: LoadState<WorkedDay> = .loading
    private let assetID: String

    init(assetID: String) { self.assetID = assetID }

    func load(day: String) async {
        track = .loading
        worked = .loading
        async let route = Self.read { try await MachinesAPI.track(self.assetID, day: day) }
        async let parcels = Self.read { try await MachinesAPI.worked(self.assetID, day: day) }
        let (readTrack, readWorked) = await (route, parcels)
        // A later day chosen meanwhile has its own load; this one's answer
        // is for the day it asked about.
        guard !Task.isCancelled else { return }
        track = readTrack
        worked = readWorked
    }

    private static func read<T: Equatable & Sendable>(_ body: @Sendable () async throws -> T) async -> LoadState<T> {
        do { return .loaded(try await body(), .fresh) } catch { return .failed(UserMessage.text(for: error)) }
    }
}
