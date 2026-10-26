import SwiftUI

/// The bar's «Изтегли PDF»: the journal's own document icon, a spinner while
/// the pages are made.
struct TreatmentDocumentButton: View {
    let document: TreatmentDocument
    let handle: String

    var body: some View {
        Button {
            Task { await document.download(handle) }
        } label: {
            if document.generating {
                ProgressView()
            } else {
                Label("Изтегли PDF", systemImage: "doc.richtext")
            }
        }
        .disabled(document.generating)
        .accessibilityLabel(document.generating ? "Изготвяне на PDF" : "Изтегли PDF")
        // The line the page used to print under the button: which pages.
        .accessibilityHint(TreatmentSavedView.documentNote)
        .accessibilityInputLabels(A11y.spokenNames("Изтегли PDF", "Изтегли", "Download PDF", "Download"))
    }
}
