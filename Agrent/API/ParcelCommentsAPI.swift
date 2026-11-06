import Foundation

/// A parcel's comments (#465, agri-saas #2476): the comments on its tasks
/// and each closed task's closing note, newest first, over the tasks
/// `parcelTasksPath` lists. One read per parcel, which is what the owner's
/// «history (incl. comment)» needs on a mechanisator's phone in a field.
enum ParcelCommentsAPI {
    /// The parcel's id in the PATH, as its other routes take it, and no
    /// query, for `WorkItemAPI.listPath`'s reason.
    static func path(_ parcelID: String) -> String {
        "\(FarmPath.root)/agro/parcels/\(URLEscape.segment(parcelID))/comments"
    }

    /// The longest note the server takes (`PARCEL_COMMENT_TOO_LONG`).
    static let maxNote = 2000

    /// A note on the parcel itself (owner, 2026-11-06): `POST`, the same
    /// path, `{ body }`. The key is the sheet's, minted when it opens and
    /// reused on a retry: a replay returns the ORIGINAL note, never a second.
    static func createNote(parcelID: String, body: String, idempotencyKey: String) async throws {
        _ = try await APIClient.shared.postReturningData(
            path(parcelID), body: ["body": body], idempotencyKey: idempotencyKey)
    }

    /// A note's own path, for its delete.
    static func notePath(_ parcelID: String, _ commentID: String) -> String {
        "\(path(parcelID))/\(URLEscape.segment(commentID))"
    }

    /// Deletes a note (owner, 2026-11-06: deletable by its author or a farm
    /// OWNER/ADMIN; a soft delete, `200 { ok: true }`). A 404 is done: the
    /// phone offers it only to those the server allows, so a 404 is a note
    /// already gone, and the list read after it shows the truth either way.
    static func deleteNote(parcelID: String, commentID: String) async throws {
        do {
            _ = try await APIClient.shared.deleteReturningData(notePath(parcelID, commentID))
        } catch let error where ParcelHistoryAPI.isAlreadyDeleted(error) {
            return
        }
    }

    /// `{rows, truncated}`, the task list's envelope, so a capped list says so.
    static func decode(from data: Data) async throws -> ParcelComments {
        let page = try await APIClient.shared.decode(data, as: PagedResponse<ParcelComment>.self)
        return ParcelComments(items: page.items, truncated: page.truncated)
    }
}

struct ParcelComments: Equatable, Sendable {
    let items: [ParcelComment]
    let truncated: Bool
}

/// One comment on one of the parcel's tasks, the note its closing left, or
/// a note on the parcel itself (owner, 2026-11-06: a comment "living only in
/// the history page of a parcel"; agri-saas `kind: "PARCEL"`).
struct ParcelComment: Decodable, Identifiable, Equatable, Sendable {
    enum Kind: String, LenientDecodable, Sendable {
        case comment = "COMMENT"
        case resolution = "RESOLUTION"
        /// A note on the field, on no task: `taskId`, `taskKey` and
        /// `taskTitle` are null.
        case parcel = "PARCEL"
        case unknown = "UNKNOWN"

        static var unknownCase: Self { .unknown }
    }

    /// Stable across reads: the comment's own id, or `resolution:<taskId>`.
    let id: String
    /// NULL on a parcel's own note, which is on no task. Optional before
    /// the server sent one: a required field here would have failed the
    /// whole list the day a parcel had a note.
    let taskId: String?
    let taskKey: String?
    let taskTitle: String?
    let kind: Kind
    let body: String
    /// The comment's own time, or when the task was closed.
    let createdAt: Date?
    /// The comment's author, `TaskComment`'s `UserRef`. NIL on a closing
    /// note, by design: the task holds no column saying who wrote it, and
    /// the phone names nobody the data doesn't (2026-10-29).
    let createdBy: WorkItemSummary.Assignee?

    /// What it says, as stored.
    var text: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Who, or what: the author of a comment; for a closing note, that it
    /// is one, and no name.
    var who: String? {
        switch kind {
        case .resolution: "При затваряне на задачата"
        case .comment, .parcel, .unknown: createdBy?.displayName
        }
    }

    /// The task it is on, as a row of Задачи names it; nil for a parcel's
    /// own note.
    var task: String? {
        let parts = [taskKey?.recorded, taskTitle?.recorded].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
