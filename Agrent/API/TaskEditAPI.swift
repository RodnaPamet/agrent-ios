import Foundation

/// «Редактирай» on a task (agrent-ios#382, owner 2026-10-21): title,
/// description, due day and assignee, on the phone as on the web's edit form.
///
/// ── Two routes, as the server splits them ──
///
/// `PATCH /api/t/{slug}/tasks/{id}` (`TaskUpdateRequest`) takes the fields,
/// partially. Assignment is its own route, `POST …/assign`
/// (`TaskAssignRequest`, `null` clears it), because that is where the server
/// records who assigned what and tells the assignee. Each is sent only when
/// its part changed, so an untouched assignee is not a second «you were
/// assigned».
///
/// ── No lock, no key ──
///
/// The task PATCH reads no `If-Match` (the task row has no version) and
/// neither route reads an `Idempotency-Key`. Both set a state rather than add
/// a row, so sending one twice leaves the same task. Last write wins, as on
/// the web.
enum TaskEditAPI {
    static func assignPath(_ id: String) -> String { "\(WorkItemAPI.detailPath(id))/assign" }

    /// Only the keys that changed. A cleared description or due day goes out
    /// as an explicit `null`, which the route reads as "remove"; an absent
    /// key leaves the field as it is.
    struct Patch: Encodable, Equatable, Sendable {
        var title: String?
        /// nil: unchanged. `.some(nil)`: cleared.
        var description: String??
        /// nil: unchanged. `.some(nil)`: cleared.
        var dueAt: String??

        var isEmpty: Bool { title == nil && description == nil && dueAt == nil }

        private enum CodingKeys: String, CodingKey { case title, description, dueAt }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(title, forKey: .title)
            if let description { try c.encode(description, forKey: .description) }
            if let dueAt { try c.encode(dueAt, forKey: .dueAt) }
        }
    }

    struct Assignment: Encodable, Equatable, Sendable {
        /// Encoded even when nil: the route requires the key, and null is
        /// "nobody".
        let assigneeUserId: String?

        private enum CodingKeys: String, CodingKey { case assigneeUserId }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(assigneeUserId, forKey: .assigneeUserId)
        }
    }

    static func update(_ id: String, _ patch: Patch) async throws {
        _ = try await APIClient.shared.patchReturningData(WorkItemAPI.detailPath(id), body: patch)
    }

    static func assign(_ id: String, to userID: String?) async throws {
        _ = try await APIClient.shared.postReturningData(
            assignPath(id), body: Assignment(assigneeUserId: userID), idempotencyKey: nil
        )
    }
}

/// What «Редактирай» works out, kept pure so a test reads the rules.
enum TaskEdit {
    /// Whether to OFFER «Редактирай»: to the task's creator and the farm's
    /// administrators (owner, 2026-10-21), and only to someone who may write
    /// here.
    ///
    /// The server allows more today: `updateTask` checks `assertCanWriteTasks`
    /// alone, so any member who can write tasks may edit any task. The
    /// owner's rule is what the phone offers. Enforcing it is a server rule,
    /// agri-saas's to make. `mayAdmin` fails open, as `mayWrite` does, so a
    /// farm that hasn't told its tier offers the button and the server's
    /// answer is read out.
    static func mayEdit(_ item: WorkItem, me: CurrentUser?) -> Bool {
        guard let me, me.mayWrite else { return false }
        return item.createdByUserId == me.id || me.mayAdmin
    }

    /// The form as the task stands. A description the server couldn't
    /// decrypt opens empty rather than as an envelope to edit; it is sent
    /// only if somebody types over it.
    static func draft(from item: WorkItem, now: Date = Date()) -> NewTaskDraft {
        var draft = NewTaskDraft(due: item.dueAt ?? now)
        draft.title = item.title
        let description = item.description ?? ""
        draft.details = WorkItemSummary.Assignee.isCipherEnvelope(description) ? "" : description
        draft.hasDue = item.dueAt != nil
        draft.assigneeID = item.assigneeUserId
        return draft
    }

    /// The picker's people, with the task's current assignee kept in. The
    /// assignable list can leave them out (someone who has since left the
    /// farm, or a list that didn't load), and a picker whose selection has
    /// no row would read «Без изпълнител» over a task that has one.
    static func choices(_ base: [AssignableUsersStore.Choice],
                        keeping assignee: WorkItemSummary.Assignee?) -> [AssignableUsersStore.Choice] {
        guard let assignee, !base.contains(where: { $0.id == assignee.id }) else { return base }
        return base + [AssignableUsersStore.Choice(id: assignee.id,
                                                   label: assignee.displayName ?? "Член без име")]
    }

    /// What changed between the form as opened and as it stands now.
    struct Changes: Equatable, Sendable {
        var patch: TaskEditAPI.Patch
        /// nil: unchanged. `.some(nil)`: unassigned.
        var assignee: String??

        var isEmpty: Bool { patch.isEmpty && assignee == nil }
    }

    /// Compared trimmed, as `NewTaskDraft.body` sends them, so a space typed
    /// and removed is no change. A due day is compared as the day, not the
    /// instant: the server's may carry a time, and an untouched day must not
    /// be rewritten to midnight.
    static func changes(from original: NewTaskDraft, to edited: NewTaskDraft) -> Changes {
        var patch = TaskEditAPI.Patch()
        let title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != original.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            patch.title = title
        }
        let details = edited.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if details != original.details.trimmingCharacters(in: .whitespacesAndNewlines) {
            patch.description = .some(details.isEmpty ? nil : details)
        }
        if dueDay(original) != dueDay(edited) {
            patch.dueAt = .some(edited.hasDue ? BgDate.dueInstant(edited.due) : nil)
        }
        let assignee: String?? = edited.assigneeID == original.assigneeID ? nil : .some(edited.assigneeID)
        return Changes(patch: patch, assignee: assignee)
    }

    private static func dueDay(_ draft: NewTaskDraft) -> String? {
        draft.hasDue ? BgDate.isoDay(draft.due) : nil
    }
}
