import Foundation
import Observation

/// The open farm's notifications and how many are unread: the «Известия»
/// list, the count on its menu row, and its badge on the bar (#471). Shared,
/// as Борса's unread count is (`ExchangeUnreadStore`), and reset at sign-out.
@Observable
@MainActor
final class NotificationsStore {
    static let shared = NotificationsStore()

    private(set) var state: LoadState<[AppNotification]> = .loading
    /// Whose list `state` is: a list read for another farm counts nothing.
    private(set) var farm: String?
    var message: String?

    @ObservationIgnored private var refreshing = false

    typealias Read = @Sendable () async throws -> [AppNotification]
    typealias MarkRead = @Sendable (String) async throws -> Void
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let send: MarkRead
    /// The open farm, `FarmPath.openSlug`; a test holds its own.
    @ObservationIgnored private let openFarm: @MainActor () -> String?

    init(read: @escaping Read = { try await NotificationsAPI.list() },
         markRead: @escaping MarkRead = { try await NotificationsAPI.markRead($0) },
         openFarm: @escaping @MainActor () -> String? = { FarmPath.openSlug }) {
        self.read = read
        self.send = markRead
        self.openFarm = openFarm
    }

    /// Unread, on the open farm only.
    var unreadCount: Int {
        guard farm != nil, farm == openFarm() else { return 0 }
        return state.value?.filter { !$0.read }.count ?? 0
    }

    /// A read of the list. Not for a MECHANISATOR, whose role the server's
    /// operator lockdown keeps off this route: a 403 for a badge helps nobody.
    /// A failure keeps what is on screen.
    func refresh() async {
        guard let farm = openFarm(), !refreshing else { return }
        if let me = CurrentUserStore.shared.user, me.isOperator { return }
        refreshing = true
        defer { refreshing = false }
        let epoch = SessionEpoch.current
        do {
            let items = try await read()
            guard SessionEpoch.isCurrent(epoch), farm == openFarm() else { return }
            self.farm = farm
            state = .loaded(items, .fresh)
        } catch {
            if state.value == nil || self.farm != farm {
                self.farm = farm
                state = .failed(UserMessage.text(for: error))
            }
        }
    }

    /// Opened: read at once on the phone, then told to the server. A refusal
    /// reads the list again, which has the server's own answer.
    func markRead(_ notification: AppNotification) async {
        guard !notification.read, let items = state.value else { return }
        state = .loaded(items.map { $0.id == notification.id ? $0.markedRead() : $0 }, .fresh)
        do {
            try await send(notification.id)
        } catch {
            await refresh()
        }
    }

    func reset() {
        state = .loading
        farm = nil
        message = nil
    }
}
