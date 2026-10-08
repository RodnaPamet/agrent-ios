import SwiftUI

/// «Коментари» at the foot of a task (agrent-ios#225): what has been said on
/// it, oldest first, and a field to add to it.
///
/// Owner, 2026-10-08: «the tasks should have comment section at the bottom
/// for the mechanisator to leave a comment». The comments come with the task
/// (`WorkItem.comments`), so they are on screen whenever the task is — with
/// no signal too, from the task's cached copy. Writing one needs signal.
struct TaskCommentsSection: View {
    let comments: [TaskComment]
    /// `TaskCommentRules.mayComment` — no composer for a READER, nor before
    /// the app knows who is signed in.
    let mayComment: Bool
    @Binding var draft: String
    let sending: Bool
    let failure: String?
    /// Sends the comment as rich text; the caller clears the draft when it lands.
    let send: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The task screen's section heading, as «Парцели» has.
            Text("Коментари")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            if comments.isEmpty {
                Text("Няма коментари.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(comments) { comment in
                    CommentRow(comment: comment)
                }
            }
            if mayComment {
                composer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdict: TaskCommentRules.Verdict { TaskCommentRules.validate(draft) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure {
                // Stated where the draft is, and the draft kept: a refused
                // comment that vanished would read as one that was posted.
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(title: "Коментар", prompt: "Напишете коментар…", text: $draft)
                sendButton
            }
            if verdict == .tooLong {
                Text("Коментарът е твърде дълъг. Съкратете го.")
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The composer's arrow, as Борса's: the spoken name says what is sent.
    private var sendButton: some View {
        Button {
            guard case .sendable(let html) = verdict else { return }
            Task { await send(html) }
        } label: {
            Group {
                if sending {
                    ProgressView()
                } else {
                    Label("Изпрати коментара", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(sending || !verdict.isSendable)
        .accessibilityLabel("Изпрати коментара")
        .accessibilityInputLabels(A11y.Spoken.sendComment)
    }
}

/// One comment: who and when on one line, what under it.
private struct CommentRow: View {
    let comment: TaskComment

    private var author: String? { comment.createdBy?.displayName }
    private var when: String? { comment.createdAt.map { BgDate.messageTime($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetaRow {
                if let author {
                    Text(author).fontWeight(.medium)
                }
                if author != nil, when != nil { MetaSeparator() }
                if let when {
                    Text(when).foregroundStyle(Palette.secondaryText)
                }
            }
            .font(.footnote)
            Text(comment.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop, from the values — never the rendered `·`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([author, when, comment.text]))
    }
}

/// What a comment may be before it is sent, and who may send one (#225).
enum TaskCommentRules {
    /// The route's `maxLength` for `body` — checked on the RICH TEXT that is
    /// sent, in UTF-16 units (a JavaScript string's `length`), since the
    /// escaping in `RichText.html(fromPlainText:)` makes it longer than what
    /// was typed.
    static let maxLength = 10_000

    /// Anyone but a READER (`assertCanCommentOnTasks`). Nobody before `/me`
    /// has answered: the composer waits rather than offering a send the
    /// server may refuse.
    static func mayComment(_ me: CurrentUser?) -> Bool {
        guard let me else { return false }
        return me.role?.uppercased() != "READER"
    }

    enum Verdict: Equatable {
        case empty
        case tooLong
        /// Send this: the trimmed text as rich text.
        case sendable(String)

        var isSendable: Bool {
            if case .sendable = self { return true }
            return false
        }
    }

    static func validate(_ draft: String) -> Verdict {
        guard let html = RichText.html(fromPlainText: draft) else { return .empty }
        return html.utf16.count > maxLength ? .tooLong : .sendable(html)
    }
}
