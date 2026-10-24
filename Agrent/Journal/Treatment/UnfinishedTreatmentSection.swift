import SwiftUI

/// On a treatment's entry: whether the server finished it, and, when it
/// can't, the administrator's way to end it (#326, owner 2026-10-15).
///
/// ── Why the entry's screen reads the server here ──
///
/// The list's row counts the ДНЕВНИК entries a treatment has, not the
/// parcels it was sent for. So «2 парцела» reads the same whether two were
/// sent or three were and one never made it onto the register. Only the
/// read by handle knows the difference. Shows nothing while it hasn't
/// answered, if it can't be reached, and for a finished treatment, which is
/// almost every one, so the screen stays as it was for them.
///
/// ── The entry's screen reads it (#428) ──
///
/// This view used to read for itself, from a `.task` on a `Group` holding
/// only `if let progress, !progress.complete { … }`. Before the read that
/// Group holds no view, and a modifier on no view never runs, so the read
/// never started and the section never showed. Now `JournalDetailView`
/// reads (`read`) and draws this only for an unfinished treatment. An empty
/// stack to hang the read on would add its spacing to every treatment.
///
/// ── Who is offered the abandon ──
///
/// ADMIN only on the server (`assertCanAdmin`), and here on its `canAdmin`
/// for the open farm (`CurrentUser.mayAdmin`). Anyone else is told who can.
/// It removes the whole treatment, the entries already on the register
/// included, so it sits behind a confirmation that says so.
struct UnfinishedTreatmentSection: View {
    let handle: String
    /// The entry's reading, and this section's after a refused abandon.
    @Binding var progress: TreatmentProgress?
    var recorder: TreatmentRecorder = LiveTreatmentRecorder()

    @State private var confirming = false
    @State private var abandoning = false
    @State private var failure: String?
    @State private var people = CurrentUserStore.shared
    @State private var outbox = OutboxStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let progress, !progress.complete {
            unfinished(progress)
        }
    }

    /// How far the server got: nil when it holds nothing, can't be reached,
    /// or the answer can't be read. Each of those shows nothing.
    static func read(_ handle: String, with recorder: TreatmentRecorder = LiveTreatmentRecorder()) async -> TreatmentProgress? {
        try? await recorder.progress(of: handle)
    }

    private func unfinished(_ progress: TreatmentProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state(progress), systemImage: "exclamationmark.triangle")
                .font(.body)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)

            if people.user?.mayAdmin ?? true {
                abandonButton(progress)
            } else {
                Text(TreatmentAbandon.askAnAdministrator)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.body)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func abandonButton(_ progress: TreatmentProgress) -> some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            if abandoning {
                ProgressView().frame(maxWidth: .infinity)
                    .accessibilityLabel("Прекратяване")
            } else {
                Label(TreatmentAbandon.title, systemImage: "xmark.octagon")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Palette.destructive)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(abandoning)
        .accessibilityInputLabels(A11y.spokenNames(TreatmentAbandon.title, TreatmentAbandon.confirm, "Abandon"))
        // On the button that asks: the dialog animates from its trigger.
        .confirmationDialog(TreatmentAbandon.title, isPresented: $confirming, titleVisibility: .visible) {
            Button(TreatmentAbandon.confirm, role: .destructive) {
                Task { await abandon() }
            }
            .accessibilityInputLabels(A11y.spokenNames(TreatmentAbandon.confirm, "Abandon"))
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(TreatmentAbandon.confirmationText(completed: progress.completedCount))
        }
    }

    /// The server's counts, then what happens to the rest: the outbox may
    /// still be sending it (#324), may have stopped getting further, or —
    /// a save that came back short on screen and was left — nothing is.
    private func state(_ progress: TreatmentProgress) -> String {
        let counts = PendingOperation.QueuedTreatment.recordedText(progress.completedCount, of: progress.parcelCount)
        let rest: String
        if let kept = outbox.pending.first(where: { $0.id == handle })?.treatment {
            rest = kept.stalled == true
                ? PendingOperation.QueuedTreatment.restStuck
                : PendingOperation.QueuedTreatment.restResent
        } else {
            rest = Self.restNotSent
        }
        return "\(counts) \(rest)"
    }

    static let restNotSent = "Останалите не са записани."

    private func abandon() async {
        abandoning = true
        failure = nil
        let outcome = await TreatmentAbandon.run(handle, with: recorder, outbox: outbox)
        abandoning = false
        switch outcome {
        case .abandoned:
            JournalChanges.shared.changed()
            dismiss()
        case .failed(let text):
            failure = text
            // Finished meanwhile, perhaps: read again, and a complete one
            // stops offering the abandon.
            progress = await Self.read(handle, with: recorder)
        }
    }
}
