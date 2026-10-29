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

/// One comment on one of the parcel's tasks, or the note its closing left.
struct ParcelComment: Decodable, Identifiable, Equatable, Sendable {
    enum Kind: String, LenientDecodable, Sendable {
        case comment = "COMMENT"
        case resolution = "RESOLUTION"
        case unknown = "UNKNOWN"

        static var unknownCase: Self { .unknown }
    }

    /// Stable across reads: the comment's own id, or `resolution:<taskId>`.
    let id: String
    let taskId: String
    let taskKey: String?
    let taskTitle: String
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
        case .comment, .unknown: createdBy?.displayName
        }
    }

    /// The task it is on, as a row of Задачи names it.
    var task: String { [taskKey?.recorded, taskTitle.recorded].compactMap { $0 }.joined(separator: " ") }
}
