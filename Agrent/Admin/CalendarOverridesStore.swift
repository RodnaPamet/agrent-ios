import Foundation

/// «Календар: поправки» (agri-saas#3095): the live corrections, and the
/// calendar they correct, for the platform farm's console.
@MainActor
@Observable
final class CalendarOverridesStore {
    private(set) var overrides: LoadState<[CalendarOverridesAPI.Override]> = .loading
    /// Every crop with its windows from BOTH halves of the country, so a
    /// window that applies only in the south can still be corrected.
    private(set) var crops: [AgroCalendar.Crop] = []
    /// A failed write or reload, shown above the list; the list stays.
    var failure: String?

    func load() async {
        if overrides.value == nil { overrides = .loading }
        do {
            overrides = .loaded(try await CalendarOverridesAPI.list(), .fresh)
        } catch {
            if overrides.value == nil { overrides = .failed(UserMessage.text(for: error)) }
            else { failure = UserMessage.text(for: error) }
        }
        if crops.isEmpty { await loadCalendar() }
    }

    /// Each crop's windows from both regions, once each, by crop key.
    private(set) var windowsByCrop: [String: [AgroCalendar.Window]] = [:]

    private func loadCalendar() async {
        var byKey: [String: AgroCalendar.Crop] = [:]
        var order: [String] = []
        var windows: [String: [AgroCalendar.Window]] = [:]
        for region in AgroRegion.allCases {
            guard let data = try? await APIClient.shared.data(for: AgroCalendarAPI.path(region: region)),
                  let calendar = try? await AgroCalendarAPI.decode(data) else { continue }
            for crop in calendar.crops {
                if byKey[crop.key] == nil { order.append(crop.key); byKey[crop.key] = crop }
                var list = windows[crop.key] ?? []
                for w in crop.windows where !list.contains(where: { $0.id == w.id }) { list.append(w) }
                windows[crop.key] = list
            }
        }
        crops = order.compactMap { byKey[$0] }
        windowsByCrop = windows
    }

    func cropTitle(_ key: String) -> String { crops.first { $0.key == key }?.title ?? key }

    func clear(_ override: CalendarOverridesAPI.Override) async {
        do {
            try await CalendarOverridesAPI.clear(override.windowId)
            failure = nil
        } catch {
            failure = UserMessage.text(for: error)
        }
        await load()
    }
}
