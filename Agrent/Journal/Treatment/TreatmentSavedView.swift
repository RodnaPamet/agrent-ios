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
        /// Not on the server yet: kept on the phone, and sent under `handle`
        /// once it can be (#324). nil once the server has answered.
        var waiting: Waiting? = nil
    }

    /// Why a kept entry has not gone yet, and what sends it.
    enum Waiting: Equatable {
        /// No signal, or a server that could not answer: the outbox sends it.
        case signal
        /// A build the server has retired (426): the updated app sends it.
        case update

        /// What happens to it next. The update's names the update, not a
        /// connection: signal will not send it, as the spray sheet's
        /// «Запази за по-късно» says of a record it keeps on a 426.
        var note: String {
            switch self {
            case .signal: "Записът остава на телефона и се изпраща автоматично, когато има връзка."
            case .update: "Записът остава на телефона и се изпраща след обновяване на приложението."
            }
        }
    }

    static let changeLostNote = "Мероприятието беше записано още при първия опит. "
        + "Промените след него не са записани."

    /// Under «Изтегли PDF» here and on the entry's own screen (#320).
    static let documentNote = "Страниците от ДНЕВНИКА на БАБХ само с това мероприятие."

    /// Where the pages are, for an entry the server does not have yet: its
    /// handle names nothing there until it arrives (#324).
    static let documentLaterNote = "ДНЕВНИКЪТ в PDF се изтегля от записа в дневника, след като бъде изпратен."

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

    private var total: TreatmentPlace.Total {
        TreatmentPlace.total(saved.fields, treated: saved.record.treatedAreas)
    }

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
                headline
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .title)
                if let waiting = saved.waiting {
                    Text(waiting.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            if saved.waiting != nil {
                Section {
                    Text(Self.documentLaterNote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                documentSection
            }
            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .inlineTitle(saved.waiting == nil ? "Записано" : "Запазено")
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

    /// Recorded, or kept on the phone: the second is not drawn as a success,
    /// since nothing is on the register yet, nor as a warning, since nothing
    /// is wrong — the outbox banner's own icon for work on its way.
    @ViewBuilder
    private var headline: some View {
        if saved.waiting == nil {
            Label("Мероприятието е записано.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
        } else {
            Label("Мероприятието чака изпращане.", systemImage: "tray.and.arrow.up")
        }
    }

    private var documentSection: some View {
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
