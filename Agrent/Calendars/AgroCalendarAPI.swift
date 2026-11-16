import Foundation
import Observation

/// The agronomic calendar's route (agri-saas #3094).
///
/// `region` is REQUIRED and has no default on the server: one half of the
/// country's sowing dates served to the other half would be wrong without
/// anything failing. The phone sends the region the farmer picked.
enum AgroCalendarAPI {
    static let flag = "agro.calendar"

    static func path(region: AgroRegion) -> String {
        "/api/agro-calendar?region=\(region.rawValue)"
    }

    static func decode(_ data: Data) async throws -> AgroCalendar {
        try await APIClient.shared.decode(data, as: AgroCalendar.self)
    }
}

/// The calendar for the region chosen, cache first, so it opens offline once
/// it has been seen. An answer for a region no longer chosen is dropped
/// (North → South tapped quickly must not end on the North's dates).
@MainActor
@Observable
final class AgroCalendarStore {
    private(set) var state: LoadState<AgroCalendar> = .loading
    private(set) var loadedRegion: AgroRegion?
    private var asked: AgroRegion?

    func load(_ region: AgroRegion) async {
        guard loadedRegion != region || state.value == nil else { return }
        asked = region
        state = .loading
        loadedRegion = region
        await CachedResource.loadShowingCacheFirst(AgroCalendarAPI.path(region: region)) { data in
            try await AgroCalendarAPI.decode(data)
        } publish: { [weak self] answer in
            guard let self, self.asked == region else { return }
            self.state = answer
        }
        if asked == region, state.isFailed { loadedRegion = nil }
    }
}
