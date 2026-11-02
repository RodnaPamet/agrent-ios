import Foundation
import Observation

/// A list the person can make the assistant forget (#507, #521): the
/// remembered points and the past conversations, one row swiped away with
/// its five seconds of «Отмени», or all of it at once.
///
/// One store for both, not two copies of it: the window, a second swipe and
/// leaving the screen must send a row exactly once between them, and that is
/// the part worth proving once (`AssistantMemoryTests`).
///
/// Read live and never cached on disk: it is what the assistant has learned
/// about a person, and what they said to it, as personal as messaging.
///
/// ── Hidden at once, forgotten after the window ──
///
/// As an expense is (`CostRemoval`): the row leaves the list and the bar
/// under it offers «Отмени». Only once the window closes is it forgotten on
/// the server, where forgetting is for good, so «Отмени» is the only way
/// back. Leaving the screen sends it at once (`flush`); an app closed
/// inside the window forgets nothing.
@MainActor
@Observable
final class ForgettableList<Item: Identifiable & Equatable & Sendable> where Item.ID == String {
    private(set) var state: LoadState<[Item]> = .loading
    /// The row waiting out its window, for the bar's «Отмени».
    private(set) var undoable: Item?
    private(set) var hidden: Set<String> = []
    var failure: String?

    /// Swiped and not yet sent. Taken out as a send starts, so the window,
    /// a second swipe and leaving the screen send a row once between them.
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let window: Duration
    @ObservationIgnored let api: API

    /// The server, swapped in tests. `edit` only where a row can be
    /// corrected: a remembered point can, a conversation cannot.
    struct API {
        var list: @MainActor () async throws -> [Item]
        var forget: @MainActor (String) async throws -> Void
        var forgetAll: @MainActor () async throws -> Void
        var edit: (@MainActor (String, String) async throws -> Item)? = nil
    }

    init(window: Duration = TreatmentRemoval.window, api: API) {
        self.window = window
        self.api = api
    }

    /// What the list shows: everything not waiting to be forgotten.
    var items: [Item] {
        (state.value ?? []).filter { !hidden.contains($0.id) }
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.list(), .fresh)
        } catch {
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
        }
    }

    /// Swiped away: hidden now, forgotten when the window closes. A second
    /// one sends the first at once, as the bar names only one.
    func forget(_ item: Item, window override: Duration? = nil) {
        if let earlier = undoable { commitNow(earlier) }
        hidden.insert(item.id)
        pending.insert(item.id)
        undoable = item
        let window = override ?? window
        timer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(item)
        }
    }

    func undo() {
        guard let item = undoable else { return }
        timer?.cancel()
        timer = nil
        pending.remove(item.id)
        hidden.remove(item.id)
        undoable = nil
    }

    /// Leaving the screen inside the window forgets the row then. The store
    /// goes with the screen, and its timer with it, so without this the
    /// person read «Забравено» and the assistant kept it.
    func flush() {
        if let item = undoable { commitNow(item) }
    }

    private func commitNow(_ item: Item) {
        timer?.cancel()
        timer = nil
        Task { await commit(item) }
    }

    func commit(_ item: Item) async {
        guard pending.remove(item.id) != nil else { return }
        if undoable?.id == item.id { undoable = nil }
        do {
            try await api.forget(item.id)
            replace(item.id) { _ in nil }
            hidden.remove(item.id)
        } catch {
            hidden.remove(item.id)
            failure = UserMessage.text(for: error)
        }
    }

    /// «Изтрий всичко», asked first by the screen: nothing comes back.
    func forgetAll() async {
        timer?.cancel()
        timer = nil
        undoable = nil
        pending = []
        do {
            try await api.forgetAll()
            state = .loaded([], .fresh)
            hidden = []
        } catch {
            // Nothing was forgotten, the swiped one included, whose send
            // this cancelled: back in the list, as it is on the server.
            hidden = []
            failure = UserMessage.text(for: error)
        }
    }

    /// One row changed (`change` answers its new value) or gone (nil).
    func replace(_ id: String, with change: (Item) -> Item?) {
        guard case .loaded(let items, let freshness) = state else { return }
        state = .loaded(items.compactMap { $0.id == id ? change($0) : $0 }, freshness)
    }
}
