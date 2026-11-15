import Foundation
import Observation

/// «Нулирай» (#610, owner 2026-11-15): every cost of the farm deleted, so
/// the calculator starts from zero. Owner or admin, one question with the
/// count and the total, then five seconds of «Отмени», as a swiped cost has
/// (`CostRemoval`).
///
/// ── Hidden at once, sent after the window ──
///
/// The costs leave the screen when the question is answered, and the bar
/// under the list says so, with «Отмени». Only once the window closes does
/// the one `DELETE /grain/costs` go, so «Отмени» leaves nothing behind, and
/// an app closed inside the window sends nothing.
///
/// ── What the server does with it ──
///
/// A soft delete, all or nothing (agri-saas #3071). Nothing on either
/// client brings the rows back, so the window is the only way back here;
/// past it, a mistake is a support request rather than a lost season.
/// The server's count is not compared with the question's: fewer means
/// somebody deleted some in between, which is not an error.
@MainActor
@Observable
final class CostReset {
    /// What the question names: the summary's count and totals.
    struct Scope: Equatable, Sendable {
        let count: Int
        /// «1 250,00 EUR», or several currencies joined; nil when the totals
        /// could not be read, and the question then gives the count only.
        let total: String?
    }

    private enum Stage: Equatable { case idle, waiting, sending }

    private var stage: Stage = .idle
    private var timer: Task<Void, Never>?
    /// The question's switch, and what it asks about.
    var asking = false
    private(set) var scope: Scope?
    private(set) var failure: String?
    /// The refusal alert's own switch.
    var showsFailure = false
    /// Bumped by each reset the server took, so the screen reads again.
    private(set) var resets = 0

    private let window: Duration
    private let send: @MainActor () async throws -> Int

    init(window: Duration = TreatmentRemoval.window,
         send: @escaping @MainActor () async throws -> Int = { try await CostsAPI.deleteAll() }) {
        self.window = window
        self.send = send
    }

    /// The costs are off the screen: waiting out the window, or sent and
    /// not yet read again.
    var hidesCosts: Bool { stage != .idle }

    /// The bar with «Отмени» is up.
    var undoable: Bool { stage == .waiting }

    /// «Нулирай» tapped: the question, with what it would delete.
    func ask(_ scope: Scope) {
        guard stage == .idle else { return }
        self.scope = scope
        asking = true
    }

    /// The confirmed «Изтрий всички».
    func confirm(window override: Duration? = nil) {
        guard stage == .idle else { return }
        failure = nil
        showsFailure = false
        stage = .waiting
        let window = override ?? window
        timer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.commit()
        }
    }

    /// «Отмени»: the costs are back, and nothing was sent.
    func undo() {
        guard stage == .waiting else { return }
        timer?.cancel()
        timer = nil
        stage = .idle
    }

    func dismissFailure() {
        failure = nil
        showsFailure = false
    }

    /// A fresh read answered after the reset: the list's own answer stands.
    func listRead() {
        if stage == .sending { stage = .idle }
    }

    func commit() async {
        guard stage == .waiting else { return }
        timer = nil
        stage = .sending
        do {
            _ = try await send()
        } catch {
            stage = .idle
            failure = UserMessage.text(for: error)
            showsFailure = true
            return
        }
        resets += 1
    }

    /// Offered to the owner or an admin: the route's own rule, on the
    /// server's `canAdmin` for the open farm.
    nonisolated static func offered(to me: CurrentUser?) -> Bool {
        me?.mayAdmin ?? false
    }

    /// The question's scope from the summary: every type, every currency.
    nonisolated static func scope(_ summary: CostSummary?, listed: Int) -> Scope {
        guard let summary else { return Scope(count: listed, total: nil) }
        let breakdown = CostBreakdown(summary: summary, entries: [])
        return Scope(count: breakdown.count, total: breakdown.totals.isEmpty ? nil : breakdown.totals.text)
    }

    static let actionTitle = "Нулирай"
    static let confirmButton = "Изтрий всички"
    static let confirmTitle = "Да се изтрият ли всички разходи на стопанството?"

    nonisolated static func message(_ scope: Scope) -> String {
        let count = Plural.bg(scope.count, "разход", "разхода")
        guard let total = scope.total else { return "\(count). Калкулаторът ще започне от нула." }
        return "\(count), общо \(total). Калкулаторът ще започне от нула."
    }

    nonisolated static func removedText(_ scope: Scope?) -> String {
        guard let scope else { return "Всички разходи са изтрити." }
        return "Изтрити: " + Plural.bg(scope.count, "разход", "разхода") + "."
    }

    nonisolated static func announcement(_ scope: Scope?) -> String {
        "\(removedText(scope)) Може да се върнат само с «Отмени», докато лентата е на екрана."
    }
}
