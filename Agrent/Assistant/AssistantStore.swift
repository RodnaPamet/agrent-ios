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
            /// The answer so far, as it is written (#587): provisional
            /// until the whole `answer` replaces it.
            case streaming(String)
            /// The answer, the screens it points at, and what stopped it
            /// short, if anything did.
            case answered(String, links: [AssistantLink] = [], note: String?, proposal: AssistantProposal? = nil,
                          promotions: [AssistantPromotion] = [])
            /// Refused or failed: the sentence that says why.
            case unanswered(String)
        }

        var isWorking: Bool {
            switch phase {
            case .working, .streaming: true
            default: false
            }
        }
    }

    typealias Asker = @MainActor (AssistantRequest) async throws -> AsyncThrowingStream<AssistantEvent, Error>

    private(set) var turns: [Turn] = []
    var draft = ""
    /// A turn's stream is open: from the question until `refusal`, `halt`
    /// or `done` — past the answer, which can come before a `halt`.
    private(set) var asking = false
    /// The server's conversation, once it has named one: sent back with
    /// every next question until «Нов разговор».
    private(set) var conversationId: String?
    /// A past conversation opened with its oldest turns left out (#525):
    /// the sheet says so above the first one shown.
    private(set) var earlierLeftOut = false
    private var running: Task<Void, Never>?
    private let asker: Asker
    /// The connection kept up while the person steps out of the app.
    let keepAlive: AssistantKeepAlive

    init(ask: @escaping Asker = { try await AssistantAPI.ask($0) },
         keepAlive: AssistantKeepAlive = AssistantKeepAlive()) {
        self.asker = ask
        self.keepAlive = keepAlive
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
        UsageEvents.shared.record(.assistantAsked)
        let index = turns.count - 1
        let request = AssistantRequest(question: question, pageContext: context, conversationId: conversationId)
        running = Task { await run(request, at: index) }
    }

    /// «Нов разговор»: the next question starts a fresh conversation, and the
    /// screen clears. Nothing is deleted: the server keeps every exchange.
    func newConversation() {
        stop()
        turns = []
        conversationId = nil
        earlierLeftOut = false
    }

    /// A past conversation, opened from «Минали разговори» (#525): its turns
    /// on screen, and the next question continues it (`conversationId`,
    /// agri-saas #2694), as a follow-up in the same sheet would.
    func resume(_ past: AssistantMemoryAPI.PastConversation) {
        stop()
        turns = Self.turns(from: past.items)
        conversationId = past.id
        earlierLeftOut = past.truncated
    }

    /// A transcript as the sheet's turns: each question with the answer
    /// after it. A question with none says the answer was not kept; an
    /// answer whose question was left out (the oldest go first) stands under
    /// «(по-ранен въпрос)»; a turn the server could not read says so.
    nonisolated static func turns(from items: [AssistantMemoryAPI.PastConversation.Item]) -> [Turn] {
        var turns: [Turn] = []
        for item in items {
            let text = item.text ?? AssistantText.unreadableTurn
            switch item.role {
            case .user:
                turns.append(Turn(question: text, phase: .unanswered(AssistantText.answerNotKept)))
            case .assistant:
                if let last = turns.indices.last, case .unanswered(AssistantText.answerNotKept) = turns[last].phase {
                    turns[last].phase = .answered(text, note: nil)
                } else {
                    turns.append(Turn(question: AssistantText.earlierQuestion, phase: .answered(text, note: nil)))
                }
            }
        }
        return turns
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
        keepAlive.end()
        if let last = turns.indices.last, turns[last].isWorking {
            turns[last].phase = .unanswered(AssistantText.interrupted)
        }
    }

    func run(_ request: AssistantRequest, at index: Int) async {
        keepAlive.begin()
        defer {
            keepAlive.end()
            if !Task.isCancelled { asking = false }
        }
        // The stream opened: a connection lost from here on was lost
        // mid-answer, and says so.
        var opened = false
        var answer: String?
        var answerLinks: [AssistantLink] = []
        var answerProposal: AssistantProposal?
        var answerPromotions: [AssistantPromotion] = []
        // The halt that was said, if any: `done` follows it (agri-saas: answer,
        // then halt, then done) and may add what the halt did not say.
        var halted: (code: String, note: String)?
        // The answer as it arrives, before `answer` (#587).
        var stream = AssistantStream()
        do {
            let events = try await asker(request)
            opened = true
            for try await event in events {
                switch event {
                case .conversation(let id):
                    conversationId = id
                case .thinking:
                    if answer == nil { turns[index].phase = .working(AssistantText.thinking) }
                case .toolCall(let name):
                    if answer == nil { turns[index].phase = .working(AssistantText.reading(name)) }
                case .toolResult:
                    // Read; the model writes next, unless it asks for more.
                    if answer == nil { turns[index].phase = .working(AssistantText.writing) }
                case .answerDelta(let text, let seq, let restarted):
                    guard answer == nil else { continue }
                    stream.apply(text, seq: seq, restarted: restarted)
                    let shown = stream.visible
                    if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        turns[index].phase = .streaming(shown)
                    }
                case .answer(let text, let links, let proposal, let promotions):
                    answer = text
                    answerLinks = links
                    answerProposal = proposal
                    answerPromotions = promotions
                    turns[index].phase = .answered(text, links: links, note: nil, proposal: proposal,
                                                   promotions: promotions)
                case .refusal(let reason, let message):
                    // Any answer already shown goes: a refusal is "no answer",
                    // and an egress block discards it outright.
                    turns[index].phase = .unanswered(AssistantText.said(message, else: AssistantText.refusal(reason)))
                    return
                case .halt(let outcome, let message):
                    let note = AssistantText.said(message, else: AssistantText.halt(outcome))
                    halted = (outcome, note)
                    // A halt keeps what was released (backend 1): with no
                    // whole answer, the part that streamed is the answer.
                    if answer == nil, !stream.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        answer = stream.text
                    }
                    turns[index].phase = answer.map {
                        .answered($0, links: answerLinks, note: note, proposal: answerProposal,
                                  promotions: answerPromotions)
                    } ?? .unanswered(note)
                case .done(let truncatedAny, let partialAny):
                    // A turn that was partial AND ran out of time is halted
                    // for the time; the partial fact rides on `done` and is
                    // said too, so an answer from 24 of 30 parcels never
                    // reads as complete (agri-saas #2648).
                    var notes = halted.map { [$0.note] } ?? []
                    if partialAny, halted?.code != "ASSISTANT_PARTIAL_DATA" {
                        notes.append(AssistantText.halt("ASSISTANT_PARTIAL_DATA"))
                    }
                    if truncatedAny, halted?.code != "ASSISTANT_TRUNCATED_RESULT" {
                        notes.append(AssistantText.halt("ASSISTANT_TRUNCATED_RESULT"))
                    }
                    if let answer {
                        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
                        turns[index].phase = .answered(answer, links: answerLinks, note: note, proposal: answerProposal,
                                                       promotions: answerPromotions)
                    } else if halted == nil {
                        turns[index].phase = .unanswered(AssistantText.noAnswer)
                    }
                    return
                case .unknown:
                    continue
                }
            }
            // Closed with no `refusal`, `halt` or `done`. After a halt that
            // is the halt's ending, already shown.
            if !Task.isCancelled, halted == nil { turns[index].phase = .unanswered(AssistantText.interrupted) }
        } catch {
            guard !Task.isCancelled else { return }
            turns[index].phase = .unanswered(
                opened && Self.isLostConnection(error) ? AssistantText.lostMidAnswer : Self.sentence(for: error))
        }
    }

    /// A refusal before the stream opened: 404 (agri-saas #2599: the flag
    /// off makes the surface not exist) or 204 (the contract's first draft)
    /// is "off"; the coded ones have their sentences in `UserMessage`; a
    /// dropped connection is the transport's own sentence.
    /// The network went while the answer was coming: the person left the
    /// app past iOS's grace, or the signal did.
    nonisolated static func isLostConnection(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .timedOut]
            .contains(error.code)
    }

    nonisolated static func sentence(for error: Error) -> String {
        switch error {
        case APIClient.APIError.http(204, _, _, _, _), APIClient.APIError.http(404, _, _, _, _):
            return AssistantText.switchedOff
        default:
            return UserMessage.text(for: error)
        }
    }
}
