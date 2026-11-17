import QuickLook
import SwiftUI

/// The download the assistant offered (#661): its label on a button; a tap
/// makes the PDF and opens it in Quick Look, where Share is. A campaign can
/// take a while, so the button turns into a spinner and stays put. An empty
/// period says so in the Дневник's own words.
struct AssistantDocumentButton: View {
    let document: AssistantDocument
    @State private var making = false
    @State private var file: URL?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await make() }
            } label: {
                HStack(spacing: 6) {
                    if making {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.richtext")
                    }
                    Text(document.label)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline.weight(.semibold))
            }
            .disabled(making)
            .accessibilityLabel(document.label)
            .accessibilityHint(AssistantDocumentText.hint)
            .accessibilityInputLabels(A11y.spokenNames(document.label, "Дневник", "PDF"))
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .quickLookPreview($file)
    }

    private func make() async {
        guard !making else { return }
        making = true
        failure = nil
        defer { making = false }
        do {
            file = try await AssistantDocumentAPI.make(document)
        } catch {
            let sentence = AssistantDocumentAPI.failure(error, for: document)
            failure = sentence
            AccessibilityNotification.Announcement(sentence).post()
        }
    }
}

enum AssistantDocumentText {
    static let hint = "Прави PDF документа и го отваря"
}
