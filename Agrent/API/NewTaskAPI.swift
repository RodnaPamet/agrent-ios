import Foundation

/// «Нова задача» (agrent-ios#372): `POST /api/t/{slug}/tasks`
/// (`TaskCreateRequest`). `title` is required, and `description`, `dueAt`
/// and `assigneeUserId` are optional.
///
/// ── The web's defaults, sent as the web sends them ──
///
/// `type: TASK` and `severity: MEDIUM` are what `useNewTaskForm` starts
/// from and sends. The phone doesn't ask for them. No priority (owner,
/// 2026-10-09).
///
/// ── NOT idempotent ──
///
/// The route honours no `Idempotency-Key`, so a save whose answer is lost
/// may have made the task. The form says so instead of promising that a
/// retry is safe, and never retries on its own.
enum NewTaskAPI {
    static var path: String { WorkItemAPI.listPath }

    /// Who the server allows in a title (`z.string().min(1).max(500)`).
    static let titleMaxLength = 500
    static let descriptionMaxLength = 10_000

    struct Body: Encodable, Equatable, Sendable {
        let title: String
        let type = "TASK"
        let severity = "MEDIUM"
        let description: String?
        let dueAt: String?
        let assigneeUserId: String?

        private enum CodingKeys: String, CodingKey {
            case title, type, severity, description, dueAt, assigneeUserId
        }
    }

    /// The created task's id, read leniently: a 201 whose body can't be
    /// read is still a task on the list, which the reload shows.
    static func create(_ body: Body) async throws -> String? {
        let data = try await APIClient.shared.postReturningData(path, body: body, idempotencyKey: nil)
        struct Created: Decodable { let id: String? }
        return (try? JSONDecoder().decode(Created.self, from: data))?.id
    }
}

/// What «Нова задача» holds while it's filled in.
struct NewTaskDraft: Equatable, Sendable {
    var title = ""
    var details = ""
    var hasDue = false
    var due: Date
    /// nil is «Без изпълнител», the web's default.
    var assigneeID: String?

    init(due: Date = Date()) { self.due = due }

    /// The first thing in the way of «Създай», or nil.
    var problem: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Въведете заглавие." }
        if title.count > NewTaskAPI.titleMaxLength {
            return "Заглавието е твърде дълго — до \(NewTaskAPI.titleMaxLength) знака."
        }
        if details.count > NewTaskAPI.descriptionMaxLength {
            return "Описанието е твърде дълго — до \(NewTaskAPI.descriptionMaxLength) знака."
        }
        return nil
    }

    /// The request, trimmed. Nothing blank goes out.
    var body: NewTaskAPI.Body {
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewTaskAPI.Body(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: details.isEmpty ? nil : details,
            dueAt: hasDue ? BgDate.dueInstant(due) : nil,
            assigneeUserId: assigneeID
        )
    }
}

/// «Създай» with parcels (#388): the task, then one link per parcel.
///
/// ── Not one request, so it can half-land ──
///
/// The create honours no key and the links come after it. So once the task
/// exists it is never created again: a link that failed is retried on its
/// own, and the person can finish without it. Only what isn't linked yet is
/// sent; a parcel linked by a send whose answer was lost answers 409, which
/// `TaskLinksAPI` counts as linked.
enum NewTaskSave {
    typealias Link = @Sendable (_ parcelID: String, _ taskID: String) async throws -> Void

    /// The parcels that were linked, one request at a time. On a weak
    /// connection parallel requests compete for the same scrap of bandwidth
    /// and all fail; one at a time, the early ones land (`OfflinePrefetch`).
    static func link(_ parcelIDs: [String], to taskID: String, with link: Link) async -> Set<String> {
        var linked = Set<String>()
        for id in parcelIDs {
            if (try? await link(id, taskID)) != nil { linked.insert(id) }
        }
        return linked
    }

    /// What is left to send: the chosen parcels not linked yet, in a stable
    /// order so a retry asks in the same order.
    static func pending(chosen: Set<String>, linked: Set<String>) -> [String] {
        chosen.subtracting(linked).sorted()
    }

    /// Said when the task exists and some parcels didn't attach.
    static func partial(_ missing: Int) -> String {
        "Задачата е създадена, но " + (missing == 1
            ? "1 парцел не беше добавен."
            : "\(missing) парцела не бяха добавени.")
            + " Опитайте пак или завършете без тях."
    }
}
