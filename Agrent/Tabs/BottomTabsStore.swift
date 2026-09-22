import Foundation
import Observation

struct BottomTabsPayload: Encodable, Sendable {
    let order: [String]
}

@Observable
@MainActor
final class BottomTabsStore {
    static let shared = BottomTabsStore()

    /// nil means NEVER CHOSEN — draw the default. An empty array means
    /// deliberately cleared, which is a different thing and the server
    /// keeps them distinct in a nullable column. Collapsing the two is
    /// unrecoverable: "new user" and "user who removed everything" want
    /// opposite behaviour.
    private(set) var stored: [String]?

    private(set) var isSaving = false
    private(set) var saveFailure: String?

    private init() {}

    /// What the tab bar actually draws.
    ///
    /// Resolved on EVERY read, never cached as a decision. Ids the server
    /// holds that this app does not know — `/dashboard` from the web —
    /// drop out here rather than anywhere earlier, so the same stored
    /// array can mean the right thing on two clients with different
    /// surfaces.
    var bottomTabs: [AppSurface] {
        guard let stored else { return AppSurface.fallback }
        let resolved = stored.compactMap(AppSurface.init(rawValue:))
        // Everything the reader chose is unavailable here. Falling back is
        // better than an empty tab bar, which is not a preference anyone
        // expressed — it is the absence of one this client can honour.
        guard !resolved.isEmpty else { return AppSurface.fallback }
        return Array(resolved.prefix(AppSurface.capacity))
    }

    /// The surfaces NOT in the bottom row, for the app menu.
    ///
    /// This is what makes the customiser safe. Without it, removing
    /// Дневник from the bar would make the diary unreachable — a
    /// preference control that can strand a feature is a trap, not a
    /// setting. Everything off the bar is in the menu, always.
    var overflow: [AppSurface] {
        let shown = Set(bottomTabs.map(\.id))
        return AppSurface.allCases.filter { !shown.contains($0.id) }
    }

    #if DEBUG
    /// The raw stored value, so a test can assert that `[]` and `nil` stay
    /// different — the distinction is invisible through `bottomTabs`,
    /// which resolves both to the default.
    var storedForTesting: [String]? { stored }
    #endif

    func adopt(_ order: [String]?) {
        stored = order
    }

    func save(_ surfaces: [AppSurface]) async {
        let order = surfaces.prefix(AppSurface.capacity).map(\.rawValue)
        let previous = stored
        // Optimistic: the bar redraws immediately and rolls back if the
        // write is refused. A tab bar that waits on a round trip before
        // moving feels broken on a field connection.
        stored = Array(order)
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }
        do {
            _ = try await APIClient.shared.put(
                BottomTabsAPI.path,
                body: BottomTabsPayload(order: Array(order)),
                as: EmptyResponse.self
            )
        } catch {
            stored = previous
            saveFailure = UserMessage.text(for: error)
        }
    }
}

enum BottomTabsAPI {
    static let path = "/api/account/bottom-tabs"
}

/// For endpoints whose body is not read. Decodes anything, including an
/// empty body, so a 204 does not become a decode failure.
struct EmptyResponse: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
    init() {}
}
