import UIKit
import UserNotifications

/// Whether this phone shows Agrent's notifications — the iOS permission, and
/// the person's own switch in Профил (agrent-ios#272; owner, 2026-10-14).
///
/// ── Asked from «Задачи», never at launch ──
///
/// iOS shows its permission prompt ONCE; after a «Не разрешавай» only the
/// Settings app can change it. So the prompt appears only after the person
/// has read why and pressed «Включи» on the card in «Задачи» — where the
/// task assignments they would be told about are. The card can be closed,
/// and Профил's switch does the same thing later.
///
/// ── The switch is the PERSON's ──
///
/// Off removes this phone from the person's farms on the server
/// (`PushRegistrar.withdraw`) and keeps it off them. Kept on this phone per
/// person, by id, as `FarmMemory` keeps a farm: a shared phone's next person
/// is not silenced by the last one's choice. The iOS permission, by
/// contrast, is the phone's, and iOS keeps it.
@Observable
@MainActor
final class PushPermission {
    static let shared = PushPermission()

    enum Standing: Equatable {
        /// Not read yet.
        case unknown
        /// iOS has never asked — the card's case.
        case notAsked
        case allowed
        /// The person said no to iOS, or turned Agrent off in Settings. Only
        /// Settings can change it now.
        case refused
    }

    private(set) var standing: Standing = .unknown

    /// The card in «Задачи» was closed on this phone.
    private(set) var cardClosed: Bool

    /// The signed-in person switched notifications off in Профил, here.
    private(set) var switchedOff = false

    /// The card shows only while iOS can still ask.
    var showsCard: Bool { standing == .notAsked && !cardClosed }

    /// What Профил's switch shows.
    var isOn: Bool { standing == .allowed && !switchedOff }

    /// The signed-in person's switch AS STORED — what `PushRegistrar` asks
    /// before it registers. Not `switchedOff`: the registrar runs at launch,
    /// before anything on screen has called `refresh`.
    var storedSwitchedOff: Bool {
        identity.userID.map { defaults.bool(forKey: Self.switchedOffKey(for: $0)) } ?? false
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identity: SessionIdentity
    @ObservationIgnored private let readStatus: @MainActor () async -> UNAuthorizationStatus
    @ObservationIgnored private let ask: @MainActor () async -> Void
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let registrar: @MainActor () -> PushRegistrar

    static let cardClosedKey = "push.cardClosed"

    /// The person's switch, under their id — which names nobody.
    static func switchedOffKey(for userID: String) -> String { "push.off.\(userID)" }

    init(
        defaults: UserDefaults = .standard,
        identity: SessionIdentity = .shared,
        readStatus: @escaping @MainActor () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        ask: @escaping @MainActor () async -> Void = {
            // A refusal is not an error here: `refresh` reads the answer.
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        },
        openSettings: @escaping @MainActor () -> Void = {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        },
        registrar: @escaping @MainActor () -> PushRegistrar = { .shared }
    ) {
        self.defaults = defaults
        self.identity = identity
        self.readStatus = readStatus
        self.ask = ask
        self.openSettings = openSettings
        self.registrar = registrar
        self.cardClosed = defaults.bool(forKey: Self.cardClosedKey)
    }

    /// Read where iOS stands, and this person's switch. On every appearance
    /// of the card or the switch: Settings can change the answer while the
    /// app is away.
    func refresh() async {
        let status = await readStatus()
        standing = switch status {
        case .notDetermined: .notAsked
        case .denied: .refused
        // Provisional and ephemeral deliver too, quietly or for an App Clip.
        default: .allowed
        }
        switchedOff = storedSwitchedOff
    }

    /// «Включи» on the card, or the switch turned on.
    func turnOn() async {
        switch standing {
        case .refused:
            // iOS will not ask a second time; Settings is the only way.
            openSettings()
            return
        case .unknown, .notAsked:
            await ask()
            await refresh()
        case .allowed:
            break
        }
        remember(switchedOff: false)
        registrar().start()
        await registrar().sync()
    }

    /// The switch turned off: this phone leaves the person's farms.
    ///
    /// Off at ONCE, and the removals after: a switch whose state waits on a
    /// request springs back under the person's finger and then moves again.
    @discardableResult
    func turnOff() -> Task<Void, Never> {
        remember(switchedOff: true)
        let registrar = registrar()
        return Task { await registrar.withdraw() }
    }

    /// Профил's button, once iOS has been told no.
    func openSystemSettings() {
        openSettings()
    }

    func closeCard() {
        cardClosed = true
        defaults.set(true, forKey: Self.cardClosedKey)
    }

    /// Изход. The next person's switch is read from their own id; the
    /// stored one stays with its person, and the permission with the phone.
    func reset() {
        switchedOff = false
    }

    private func remember(switchedOff off: Bool) {
        switchedOff = off
        guard let userID = identity.userID else { return }
        defaults.set(off, forKey: Self.switchedOffKey(for: userID))
    }
}
