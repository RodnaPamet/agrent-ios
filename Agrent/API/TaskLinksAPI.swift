import Foundation

/// A task's parcels (agrent-ios#388): `POST /api/t/{slug}/tasks/{id}/links`
/// (`TaskLinkAddRequest`), one per parcel, after the task is created.
///
/// ── Why links, and not the create ──
///
/// `TaskCreateRequest` has no parcels. A task's parcels are its `PARCEL`
/// links, which `GET /tasks/{id}/parcels` answers (#177, drawn on the task's
/// map). The web's «Нова задача» does the same: the task first, then its
/// staged links (`useNewTaskForm`'s `pendingLinks`).
///
/// ── A second link is a conflict, which here means done ──
///
/// `(task, entityType, entityId)` is unique, and the route creates rather
/// than upserts. So the only way to send one twice, a retry after an answer
/// that was lost, answers 409. The parcel is linked either way.
enum TaskLinksAPI {
    static func path(_ taskID: String) -> String { "\(WorkItemAPI.detailPath(taskID))/links" }

    struct Body: Encodable, Equatable, Sendable {
        let entityType = "PARCEL"
        let entityId: String
        let relation = "RELATES_TO"

        private enum CodingKeys: String, CodingKey { case entityType, entityId, relation }
    }

    static func linkParcel(_ parcelID: String, to taskID: String) async throws {
        do {
            _ = try await APIClient.shared.postReturningData(
                path(taskID), body: Body(entityId: parcelID), idempotencyKey: nil)
        } catch let error as APIClient.APIError where isAlreadyLinked(error) {
            return
        }
    }

    /// A 409, in either of the shapes `APIClient` gives one.
    static func isAlreadyLinked(_ error: APIClient.APIError) -> Bool {
        switch error {
        case .conflict: true
        case .http(let status, _, _, _, _): status == 409
        default: false
        }
    }
}
