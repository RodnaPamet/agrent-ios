import QuickLook
import SwiftUI

/// «Изтегли PDF» for a treatment already on the register, from its entry's
/// screen (#320): the ДНЕВНИК pages for that one treatment, by its handle
/// (agri-saas #1822), opened in Quick Look.
///
/// Its own view, so the entry's screen stays what its header says it is —
/// read from the row, holding nothing. The PDF is the one thing read here,
/// and only on a tap.
struct TreatmentDocumentAction: View {
    let handle: String
    var recorder: TreatmentRecorder = LiveTreatmentRecorder()

    @State private var generating = false
    @State private var failure: String?
    @State private var document: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: download) {
                if generating {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Изготвяне на PDF")
                } else {
                    Label("Изтегли PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(generating)
            .accessibilityInputLabels(A11y.spokenNames("Изтегли PDF", "Изтегли", "Download PDF", "Download"))

            Text(TreatmentSavedView.documentNote)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Text(failure)
                    .font(.body)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quickLookPreview($document)
        // Removed when Quick Look closes, not on `onDisappear`, which fires
        // under the full-screen preview (`FarmRecordAPI.removeGenerated`).
        .onChange(of: document) { _, now in
            if now == nil { FarmRecordAPI.removeGenerated() }
        }
        // Said, not only drawn: the button under the cursor came back.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }
    }

    private func download() {
        guard !generating else { return }
        generating = true
        failure = nil
        Task {
            defer { generating = false }
            do {
                document = try await recorder.document(forTreatment: handle)
            } catch {
                failure = UserMessage.text(for: error)
            }
        }
    }
}
