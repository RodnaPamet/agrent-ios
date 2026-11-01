import SwiftUI

/// The bar's «Изтегли PDF»: the journal's own document icon, a spinner while
/// the pages are made.
struct TreatmentDocumentButton: View {
    let document: TreatmentDocument
    let handle: String
    /// Other work: its page of «Дневник на стопанството» (#516), named so,
    /// rather than a treatment's БАБХ pages.
    var activity = false

    private var title: String { activity ? "Дневник на стопанството" : "Изтегли PDF" }

    var body: some View {
        Button {
            Task { await document.download(handle, activity: activity) }
        } label: {
            if document.generating {
                ProgressView()
            } else {
                Label(title, systemImage: "doc.richtext")
            }
        }
        .disabled(document.generating)
        .accessibilityLabel(document.generating ? "Изготвяне на PDF" : activity ? "\(title), PDF" : title)
        // The line the page used to print under the button: which pages.
        .accessibilityHint(activity ? Self.activityNote : TreatmentSavedView.documentNote)
        .accessibilityInputLabels(activity
            ? A11y.spokenNames("Дневник на стопанството", "Изтегли PDF", "Farm diary")
            : A11y.spokenNames("Изтегли PDF", "Изтегли", "Download PDF", "Download"))
    }

    static let activityNote = "Страницата от «Дневник на стопанството» само с тази дейност."
}
