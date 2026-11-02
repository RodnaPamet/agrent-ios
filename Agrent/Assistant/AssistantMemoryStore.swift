import Foundation
import Observation

/// «Какво помни асистентът»'s state (#507): the remembered points, a point
/// swiped away with its five seconds of «Отмени», a correction, and
/// «Изтрий всичко».
///
/// Read live and never cached on disk: it is what the assistant has learned
/// about a person, as personal as messaging.
///
/// ── Hidden at once, forgotten after the window ──
///
/// As an expense is (`CostRemoval`): the point leaves the list and the bar
/// under it offers «Отмени». Only once the window closes is it forgotten on
/// the server, where forgetting is for good, so «Отмени» is the only way
/// back. Leaving the screen sends it at once (`flush`); an app closed
/// inside the window forgets nothing.
@MainActor
@Observable
final class AssistantMemoryStore {
    typealias Point = AssistantMemoryAPI.Point

    private(set) var state: LoadState<[Point]> = .loading
    /// The point waiting out its window, for the bar's «Отмени».
    private(set) var undoable: Point?
    private(set) var hidden: Set<String> = []
    var failure: String?

    /// Swiped and not yet sent. Taken out as a send starts, so the window,
    /// a second swipe and leaving the screen send a point once between them.
    @ObservationIgnored private var pending: Set<String> = []

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let window: Duration
    @ObservationIgnored private let api: API

    /// The server, swapped in tests.
    struct API {
        var list: @MainActor () async throws -> [Point] = { try await AssistantMemoryAPI.list() }
        var forget: @MainActor (String) async throws -> Void = { try await AssistantMemoryAPI.forget($0) }
        var forgetAll: @MainActor () async throws -> Void = { try await AssistantMemoryAPI.forgetAll() }
        var edit: @MainActor (String, String) async throws -> Point = { try await AssistantMemoryAPI.edit($0, text: $1) }
    }

    init(window: Duration = TreatmentRemoval.window, api: API = API()) {
        self.window = window
        self.api = api
    }

    /// What the list shows: everything not waiting to be forgotten.
    var points: [Point] {
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
    func forget(_ point: Point, window override: Duration? = nil) {
        if let earlier = undoable { commitNow(earlier) }
        hidden.insert(point.id)
        pending.insert(point.id)
        undoable = point
        let window = override ?? window
        timer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit(point)
        }
    }

    func undo() {
        guard let point = undoable else { return }
        timer?.cancel()
        timer = nil
        pending.remove(point.id)
        hidden.remove(point.id)
        undoable = nil
    }

    /// Leaving the screen inside the window forgets the point then. The
    /// store goes with the screen, and its timer with it, so without this
    /// the person read «Забравено» and the assistant kept it.
    func flush() {
        if let point = undoable { commitNow(point) }
    }

    private func commitNow(_ point: Point) {
        timer?.cancel()
        timer = nil
        Task { await commit(point) }
    }

    func commit(_ point: Point) async {
        guard pending.remove(point.id) != nil else { return }
        if undoable?.id == point.id { undoable = nil }
        do {
            try await api.forget(point.id)
            replace(point.id) { _ in nil }
            hidden.remove(point.id)
        } catch {
            hidden.remove(point.id)
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

    /// The person's own wording. Nil on success, the sentence on a refusal.
    /// A point forgotten meanwhile (from the web, say) leaves the list with
    /// the server's sentence, as there is nothing left to correct.
    func edit(_ point: Point, to text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.emptyRefusal }
        do {
            let saved = try await api.edit(point.id, String(trimmed.prefix(AssistantMemoryAPI.maxLength)))
            replace(point.id) { _ in saved }
            return nil
        } catch {
            if case APIClient.APIError.http(404, _, _, _, _) = error { replace(point.id) { _ in nil } }
            return UserMessage.text(for: error)
        }
    }

    static let emptyRefusal = UserMessage.bulgarian["MEMORY_POINT_EMPTY"] ?? "Записът не може да бъде празен."

    private func replace(_ id: String, with change: (Point) -> Point?) {
        guard case .loaded(let points, let freshness) = state else { return }
        state = .loaded(points.compactMap { $0.id == id ? change($0) : $0 }, freshness)
    }
}
