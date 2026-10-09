import Foundation

/// The green tick's form (#226): what it asks, what it sends, and who may
/// use it.
///
/// Owner, 2026-10-08: the corner button «should be replaced with a green
/// tick button, which is used only to close the task. it should open a short
/// questionnaire form — 1/ was the task successfullt completed? 2/ Which
/// types of weeds did you encounter? 3/ additional commets (optional)». And,
/// asked the same day: «Не» still closes; the weeds become the parcels' weed
/// records as well as words in the closing note; the list is the server's
/// 13 plus free text and «Няма плевели»; no other status move stays in the
/// app.
struct TaskCloseAnswers: Equatable {
    /// 1 — required.
    var completed: Bool?
    /// 2 — the catalogue's binomials picked.
    var weeds: Set<String> = []
    /// 2 — said outright, so «none» is an answer and not a skipped question.
    var noWeeds = false
    /// 2 — anything the catalogue lacks; commas separate several.
    var otherWeeds = ""
    /// 3 — optional.
    var comment = ""
}

enum TaskCloseRules {
    /// `TaskSetStatusRequest.resolution`'s `maxLength`, in the server's
    /// measure (UTF-16 units).
    static let resolutionMaxLength = 5000

    /// The tick is there when the task can still move to CLOSED and this
    /// person may move it: general write, or the task's ASSIGNEE —
    /// `setTaskStatus`'s own rule («a restricted MECHANISATOR … must be able
    /// to complete their own farm tasks»), the one `FieldOperationRules`
    /// applies to a job's lines. Not before `/me` has answered.
    static func mayClose(_ task: WorkItem, me: CurrentUser?) -> Bool {
        task.status.allowedNext.contains(.closed)
            && FieldOperationRules.mayMark(me: me, assigneeUserID: task.assigneeUserId)
    }

    /// The free-text weeds, one entry each.
    static func otherWeeds(_ answers: TaskCloseAnswers) -> [String] {
        answers.otherWeeds
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What the parcels are told: the binomials in the catalogue's order,
    /// then the free text — one list, which the server sorts into
    /// `weedKeys` and `otherWeeds`. Empty for «Няма плевели»: there is
    /// nothing to record, and the route refuses an observation of nothing.
    static func weedsToRecord(_ answers: TaskCloseAnswers) -> [String] {
        guard !answers.noWeeds else { return [] }
        return NewWeedObservation.cleaned(
            WeedCatalogue.binomials.filter(answers.weeds.contains) + otherWeeds(answers))
    }

    /// Question 1 answered, and question 2 when it is asked — a weed, one
    /// written in, or «Няма плевели». The comment is optional.
    static func isComplete(_ answers: TaskCloseAnswers, asksWeeds: Bool) -> Bool {
        guard answers.completed != nil else { return false }
        guard asksWeeds else { return true }
        return answers.noWeeds || !weedsToRecord(answers).isEmpty
    }

    /// The closing note — the resolution the server expects on CLOSED — a
    /// line per answer, in the form's words, so whoever reads the task on
    /// the web sees what the mechanisator said.
    static func resolution(_ answers: TaskCloseAnswers, asksWeeds: Bool) -> String {
        var lines = ["Изпълнена успешно: \(answers.completed == true ? "да" : "не")."]
        if asksWeeds {
            if answers.noWeeds {
                lines.append("Плевели: няма.")
            } else {
                // «Балур (Sorghum halepense)»: the Latin beside the name, as
                // the parcel's own history shows it, so the web's reader
                // knows exactly which.
                let names = WeedCatalogue.binomials.filter(answers.weeds.contains).map(WeedCatalogue.name(for:))
                    + otherWeeds(answers)
                lines.append("Плевели: \(names.joined(separator: ", ")).")
            }
        }
        let comment = answers.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { lines.append("Коментар: \(comment)") }
        return lines.joined(separator: "\n")
    }

    static func isTooLong(_ answers: TaskCloseAnswers, asksWeeds: Bool) -> Bool {
        resolution(answers, asksWeeds: asksWeeds).utf16.count > resolutionMaxLength
    }

    /// The observation's note: which task it came from, so a parcel's weed
    /// history can be traced back to the job that saw them.
    static func observationNote(_ task: WorkItem) -> String {
        "Задача \(task.key.map { "\($0): " } ?? "")\(task.title)"
    }
}

/// What the close says, in Bulgarian, ending with a full stop as `UserMessage` does.
enum TaskCloseText {
    static let inProgress = "Задачата вече се завършва."

    /// The close landed, the weeds did not reach every parcel — said under
    /// the task, with the server's reason, because the note has them and
    /// the parcel's history does not.
    static func weedsNotRecorded(parcels: Int, reason: String) -> String {
        "Задачата е завършена и плевелите са в бележката към нея, но не са записани в "
            + "\(Plural.bg(parcels, "парцел", "парцела")): \(reason)"
    }
}

