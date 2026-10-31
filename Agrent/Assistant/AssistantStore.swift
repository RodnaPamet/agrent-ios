import Foundation
import Observation

/// The assistant's conversation on this screen (#483): each question is its
/// own turn (nothing earlier is sent back), and the turns stay on screen for
/// as long as the stack they were asked on.
@MainActor
@Observable
final class AssistantStore {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var phase: Phase

        enum Phase: Equatable {
            /// Running: what it is doing, said.
            case working(String)
            /// The answer, the screens it points at, and what stopped it
            /// short, if anything did.
            case answered(String, links: [AssistantLink] = [], note: String?)
            /// Refused or failed: the sentence that says why.
            case unanswered(String)
        }

        var isWorking: Bool {
            if case .working = phase { true } else { false }
        }
    }

    typealias Asker = @MainActor (AssistantRequest) async throws -> AsyncThrowingStream<AssistantEvent, Error>

    private(set) var turns: [Turn] = []
    var draft = ""
    /// A turn's stream is open: from the question until `refusal`, `halt`
    /// or `done` — past the answer, which can come before a `halt`.
    private(set) var asking = false
    private var running: Task<Void, Never>?
    private let asker: Asker

    init(ask: @escaping Asker = { try await AssistantAPI.ask($0) }) {
        self.asker = ask
    }

    var canSend: Bool {
        !asking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft as a question, asked from where the person is.
    func send(context: AssistantPageContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !asking else { return }
        draft = ""
        asking = true
        turns.append(Turn(question: question, phase: .working(AssistantText.thinking)))
        let index = turns.count - 1
        running = Task { await run(AssistantRequest(question: question, pageContext: context), at: index) }
    }

    /// The running turn, to its end. For the tests, which must not race it.
    func settled() async {
        await running?.value
    }

    /// The sheet closed or the person stopped it: nothing more arrives, and
    /// a turn cut short says so.
    func stop() {
        running?.cancel()
        running = nil
        asking = false
        if let last = turns.indices.last, turns[last].isWorking {
            turns[last].phase = .unanswered(AssistantText.interrupted)
        }
    }

    func run(_ request: AssistantRequest, at index: Int) async {
        defer { if !Task.isCancelled { asking = false } }
        var answer: String?
        var answerLinks: [AssistantLink] = []
        do {
            let events = try await asker(request)
            for try await event in events {
                switch event {
                case .thinking:
                    if answer == nil { turns[index].phase = .working(AssistantText.thinking) }
                case .toolCall, .toolResult:
                    if answer == nil { turns[index].phase = .working(AssistantText.reading) }
                case .answer(let text, let links, _):
                    answer = text
                    answerLinks = links
                    turns[index].phase = .answered(text, links: links, note: nil)
                case .refusal(let reason, let message):
                    // Any answer already shown goes: a refusal is "no answer",
                    // and an egress block discards it outright.
                    turns[index].phase = .unanswered(AssistantText.said(message, else: AssistantText.refusal(reason)))
                    return
                case .halt(let outcome, let message, let counts):
                    let note = AssistantText.said(message, else: AssistantText.halt(outcome, counts: counts))
                    turns[index].phase = answer.map { .answered($0, links: answerLinks, note: note) } ?? .unanswered(note)
                    return
                case .done:
                    if answer == nil { turns[index].phase = .unanswered(AssistantText.noAnswer) }
                    return
                case .unknown:
                    continue
                }
            }
            // Closed with no `refusal`, `halt` or `done`.
            if !Task.isCancelled { turns[index].phase = .unanswered(AssistantText.interrupted) }
        } catch {
            guard !Task.isCancelled else { return }
            turns[index].phase = .unanswered(Self.sentence(for: error))
        }
    }

    /// A refusal before the stream opened: 404 (agri-saas #2599: the flag
    /// off makes the surface not exist) or 204 (the contract's first draft)
    /// is "off"; the coded ones have their sentences in `UserMessage`; a
    /// dropped connection is the transport's own sentence.
    nonisolated static func sentence(for error: Error) -> String {
        switch error {
        case APIClient.APIError.http(204, _, _, _, _), APIClient.APIError.http(404, _, _, _, _):
            return AssistantText.switchedOff
        default:
            return UserMessage.text(for: error)
        }
    }
}
