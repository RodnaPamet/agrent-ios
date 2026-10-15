import Foundation

/// An administrator abandoning a treatment the server can't finish (#326,
/// owner 2026-10-15). Apart from the screen, so a test can read it.
///
/// ── What it removes ──
///
/// The WHOLE treatment, the ДНЕВНИК entries already written for it included:
/// the owner's ruling on agri-saas #1860. The server soft-deletes it and keeps
/// the abandon to ADMIN, to an incomplete treatment, and to one audited
/// event. The phone adds the confirmation that names what goes.
///
/// ── And the phone's own copy ──
///
/// A treatment kept in the outbox under the same handle is dropped with it.
/// Sent again, the server refuses it (agri-saas #1869), and the person would
/// meet a refusal for work they themselves just removed.
enum TreatmentAbandon {
    enum Outcome: Equatable, Sendable {
        case abandoned
        /// Not abandoned, in the server's words: finished meanwhile
        /// (`TREATMENT_COMPLETE`), not an administrator, no signal.
        case failed(String)
    }

    /// A 404 on the route's own code counts as done. The server holds nothing
    /// under the handle, which is how it answers a treatment already
    /// abandoned, from the web or from another phone.
    @MainActor
    static func run(_ handle: String, with recorder: TreatmentRecorder, outbox: OutboxStore) async -> Outcome {
        do {
            try await recorder.abandon(handle)
        } catch let error where TreatmentAPI.isNothingRecorded(error) {
            // Already gone, so the same as done.
        } catch {
            return .failed(UserMessage.text(for: error))
        }
        await outbox.forget(handle)
        return .abandoned
    }

    /// What the confirmation says goes. With nothing on the register yet,
    /// it says that rather than «0 парцела».
    static func confirmationText(completed: Int) -> String {
        guard completed > 0 else {
            return "Ще бъде премахнато цялото мероприятие. В дневника още няма записи от него."
        }
        return "Ще бъде премахнато цялото мероприятие, заедно със записите в дневника за "
            + "\(Plural.bg(completed, "парцел", "парцела")), които вече са записани."
    }

    static let title = "Прекрати мероприятието"
    static let confirm = "Прекрати"
    /// For someone the server would refuse: who can do it instead.
    static let askAnAdministrator = "Само администратор на стопанството може да прекрати недовършено мероприятие."
}
