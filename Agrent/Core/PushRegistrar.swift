import UIKit

/// Keeps this phone registered for push with every farm its person belongs
/// to (agrent-ios#272).
///
/// ── What it does, and what it does not yet ──
///
/// It asks iOS for the APNs token on every signed-in launch, and sends it to
/// each farm (`PushAPI.register`) — again whenever the token changes or the
/// farm list gains a farm. Registering needs no permission from the person:
/// a token says where the phone is, and only an ALERT needs their yes.
///
/// It never asks for that yes. The owner's decision (2026-10-14): the ask is
/// a card in «Задачи» plus a switch in Профил, and both stay hidden until the
/// server actually delivers (agri-saas #1764 step 3) — nobody should grant
/// permission and then hear nothing.
///
/// ── Never from a development machine ──
///
/// A simulator signed in to the owner's account would register real rows on
/// production, and the unit tests run inside the app on exactly such a
/// simulator. So nothing here asks iOS for a token there — see
/// `mayRegister`.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    /// This install's APNs token, lowercase hex. The PHONE's, not a person's:
    /// Изход keeps it, and the next person to sign in registers the same
    /// token with their own farms.
    private(set) var deviceToken: String?

    /// The farms this token is registered with in THIS session. Изход and a
    /// new token both empty it.
    private(set) var registered: Set<String> = []

    /// Registrations on their way, so two overlapping `sync`s do not both
    /// send one. Keyed by token and session as well as farm: the token is the
    /// phone's and the same across people, so a marker of A's still in
    /// flight must not stand in for B's registration — nor an old token's
    /// for a new one.
    private struct Sending: Hashable {
        let farm: String
        let token: String
        let epoch: Int
    }

    private var sending: Set<Sending> = []

    private let register: @MainActor (_ token: String, _ farm: String) async throws -> Void
    private let farms: @MainActor () -> [String]

    init(
        register: @escaping @MainActor (_ token: String, _ farm: String) async throws -> Void = {
            try await PushAPI.register($0, in: $1)
        },
        farms: @escaping @MainActor () -> [String] = { FarmStore.shared.memberSlugs }
    ) {
        self.register = register
        self.farms = farms
    }

    /// False on a simulator, and under the screenshot harness — the
    /// machines this app is developed on, never a farmer's phone.
    static let mayRegister: Bool = {
        #if DEBUG
        if UITestSeam.isActive { return false }
        #endif
        return !isSimulator
    }()

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Ask iOS for the token. Every signed-in launch, as Apple asks: the
    /// token can change, and iOS answers at once when it has not.
    func start() {
        guard Self.mayRegister else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The token iOS handed over. A new one is registered with every farm
    /// afresh; the same one only where it is not registered yet.
    @discardableResult
    func adopt(_ token: Data) -> Task<Void, Never> {
        let hex = PushAPI.hex(token)
        if hex != deviceToken {
            deviceToken = hex
            registered = []
        }
        return Task { await sync() }
    }

    /// Register the token with each of the person's farms that does not have
    /// it yet. A failure is left for the next call — the next launch, return
    /// or farm-list change — rather than retried here.
    func sync() async {
        guard let token = deviceToken else { return }
        let epoch = SessionEpoch.current
        for farm in farms() {
            // Again on every pass, because each pass awaits: a person who
            // signed out while the last farm was sent is not registered with
            // the rest of their farms under whoever is signed in now.
            guard SessionEpoch.isCurrent(epoch), token == deviceToken else { return }
            let marker = Sending(farm: farm, token: token, epoch: epoch)
            guard !registered.contains(farm), !sending.contains(marker) else { continue }
            sending.insert(marker)
            do {
                try await register(token, farm)
                // Not if the session ended, or the token changed, while it
                // was on its way: `registered` now belongs to that change.
                if SessionEpoch.isCurrent(epoch), token == deviceToken {
                    registered.insert(farm)
                }
            } catch {
                Log.auth.info("push register not sent: \(Log.summary(for: error), privacy: .public)")
            }
            sending.remove(marker)
        }
    }

    /// What Изход removes from the server, read BEFORE the local clear.
    ///
    /// Every farm the person belongs to, not only those confirmed: a
    /// registration still on its way may land, and removing a row that was
    /// never made answers 200 all the same (`deleteMany`).
    func farewell(accessToken: String?) -> PushFarewell? {
        guard let deviceToken, let accessToken, !accessToken.isEmpty else { return nil }
        let all = registered.union(sending.map(\.farm)).union(farms())
        guard !all.isEmpty else { return nil }
        return PushFarewell(deviceToken: deviceToken, farms: all.sorted(), accessToken: accessToken)
    }

    /// Изход: nothing is registered for whoever signs in next. The token
    /// stays — see `deviceToken`.
    func reset() {
        registered = []
        sending = []
    }
}
