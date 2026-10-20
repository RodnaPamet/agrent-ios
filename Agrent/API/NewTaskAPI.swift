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
