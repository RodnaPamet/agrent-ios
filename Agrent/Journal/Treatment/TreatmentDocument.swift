import SwiftUI

/// «Изтегли PDF» for a treatment already on the register, from its entry's
/// screen (#320): the ДНЕВНИК pages for that one treatment, by its handle
/// (agri-saas #1822), opened in Quick Look.
///
/// ── In the bar, not the page (owner, 2026-10-26) ──
///
/// The entry's actions sit at the top right, as a task's «Редактирай» and
/// the journal's «Дневник (PDF)» do. So the read's state lives here, owned
/// by the entry's screen, which hangs the Quick Look preview on its own
/// content and says a failure there: a presentation hung on a bar item comes
/// and goes with the bar, and the bar has no room for a sentence.
@MainActor
@Observable
final class TreatmentDocument {
    private(set) var generating = false
    private(set) var failure: String?
    /// The PDF on disk while Quick Look shows it; nil closes the preview.
    var document: URL?

    @ObservationIgnored private let recorder: TreatmentRecorder
    /// An activity's page of «Дневник на стопанството» (#516).
    @ObservationIgnored private let activityDiary: @MainActor (String) async throws -> URL

    init(recorder: TreatmentRecorder = LiveTreatmentRecorder(),
         activityDiary: @escaping @MainActor (String) async throws -> URL = { try await ActivityAPI.diary(forActivity: $0) }) {
        self.recorder = recorder
        self.activityDiary = activityDiary
    }

    /// A treatment's ДНЕВНИК pages, or, for other work, its page of
    /// «Дневник на стопанството»: never the БАБХ form for an activity.
    func download(_ handle: String, activity: Bool = false) async {
        guard !generating else { return }
        generating = true
        failure = nil
        defer { generating = false }
        do {
            document = activity ? try await activityDiary(handle) : try await recorder.document(forTreatment: handle)
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
