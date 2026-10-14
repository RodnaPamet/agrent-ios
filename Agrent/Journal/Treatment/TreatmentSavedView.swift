import QuickLook
import SwiftUI

/// Step three: saved, and the entry's ДНЕВНИК pages one tap away.
struct TreatmentSavedView: View {
    struct Saved: Equatable {
        /// The treatment's handle: the key its save went out under.
        let handle: String
        let record: TreatmentRecord
        let fields: [TreatmentPlace.Field]
        let cropLabel: String?
        /// What the server kept is an earlier save, whose answer never
        /// arrived — without what the person changed after it
        /// (`TreatmentAttempt.save`). Said, because the screen below shows
        /// the entry as it was recorded, not as they last saw it.
        var changeLost = false
    }

    static let changeLostNote = "Мероприятието беше записано още при първия опит. "
        + "Промените след него не са записани."

    /// Under «Изтегли PDF» here and on the entry's own screen (#320).
    static let documentNote = "Страниците от ДНЕВНИКА на БАБХ само с това мероприятие."

    let saved: Saved
    let recorder: TreatmentRecorder
    let onDone: () -> Void

    @State private var generating = false
    @State private var failure: String?
    @State private var document: URL?
    @AccessibilityFocusState private var focus: Landing?

    /// Where VoiceOver lands: the title, or the note when a change was lost
    /// — it opens with what was recorded and is the thing to hear.
    private enum Landing { case title, note }

    private var total: TreatmentPlace.Total { TreatmentPlace.total(saved.fields) }

    /// The area is never presented as complete when it is not.
    private var withoutAreaNote: String {
        switch total.withoutArea {
        case 0: ""
        case 1: "1 парцел е без площ и не е включен в площта."
        default: "\(total.withoutArea) парцела са без площ и не са включени в площта."
        }
    }

    var body: some View {
        PageForm {
            Section {
                Label("Мероприятието е записано.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .title)
                if saved.changeLost {
                    Label(Self.changeLostNote, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($focus, equals: .note)
                }
            }
            Section {
                ValueRow("Вид") { Text(saved.record.kind.label) }
                ValueRow("Дата") { Text(BgDate.full(saved.record.date)) }
                ValueRow(saved.record.kind.inputLabel) { Text(saved.record.productName) }
                if let culture = saved.cropLabel { ValueRow("Култура") { Text(culture) } }
                ValueRow(saved.record.kind == .spray ? "Третирана площ" : "Наторена площ") {
                    Text(total.area.text).accessibilityLabel(total.area.spoken)
                }
                ValueRow("Парцели") { Text(String(total.parcels)) }
            } footer: {
                SectionFooter(withoutAreaNote)
            }
            Section {
                Button {
                    Task { await download() }
                } label: {
                    if generating {
                        ProgressView().frame(maxWidth: .infinity)
                            .accessibilityLabel("Изготвяне на PDF")
                    } else {
                        Label("Изтегли PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                    }
                }
                .disabled(generating)
                .accessibilityInputLabels(A11y.spokenNames("Изтегли PDF", "Изтегли", "Download PDF", "Download"))
            } footer: {
                SectionFooter(Self.documentNote)
            }
            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .inlineTitle("Записано")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово", action: onDone)
                    .accessibilityInputLabels(A11y.Spoken.done)
            }
        }
        .quickLookPreview($document)
        // Said, not only drawn: the button under the cursor came back.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }
        .task {
            // The steps were swapped out under VoiceOver's cursor; this says
            // where it landed.
            try? await Task.sleep(for: .milliseconds(600))
            focus = saved.changeLost ? .note : .title
        }
    }

    private func download() async {
        guard !generating else { return }
        generating = true
        failure = nil
        defer { generating = false }
        do {
            document = try await recorder.document(forTreatment: saved.handle)
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
