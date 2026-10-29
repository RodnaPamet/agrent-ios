import Foundation

/// The signed-in person's own work (#465): `GET /farm-tasks` with no query
/// is the queue of FARM_TASK and FIELD_OPERATION assigned to the caller,
/// soonest due first. Inside the operator allowlist, which is why a
/// MECHANISATOR's one screen reads it rather than `/tasks` filtered here.
enum FarmTasksAPI {
    /// NO QUERY: the route's default scope is `mine`, so the person's id
    /// never goes in a URL, which CFNetwork would write to the device log.
    static var queuePath: String { "\(FarmPath.root)/farm-tasks" }

    /// A BARE ARRAY of `FarmTaskListItem`: the list row's keys plus
    /// `completedAt`, which is what `WorkItemSummary` reads. Capped at 200
    /// by the server with no marker, which a person's own queue does not
    /// reach.
    static func decodeQueue(from data: Data) async throws -> [WorkItemSummary] {
        try await APIClient.shared.decode(data, as: [WorkItemSummary].self)
    }
}
