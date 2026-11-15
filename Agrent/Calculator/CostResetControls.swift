import SwiftUI
import UIKit

/// «Нулирай»'s screen side (#610): the question, the five seconds of
/// «Отмени» under the list, and a refusal said. `CostReset` holds the rules.
///
/// Plain modifier functions, as `costRemoval` is, for the reason it gives.
extension View {
    /// `reload` reads the costs and the calculator again once the server
    /// took the reset.
    func costReset(_ reset: CostReset, reload: @escaping @MainActor () async -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if reset.undoable { CostResetBar(reset: reset) }
        }
        .alert(CostReset.confirmTitle, isPresented: Bindable(reset).asking, presenting: reset.scope) { _ in
            Button(CostReset.confirmButton, role: .destructive) { CostResetControls.confirm(reset) }
                .accessibilityInputLabels(A11y.Spoken.deleteAll)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: { scope in
            Text(CostReset.message(scope))
        }
        .alert("Разходите не са изтрити", isPresented: Bindable(reset).showsFailure, presenting: reset.failure) { _ in
            Button("Затвори", role: .cancel) { reset.dismissFailure() }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: reset.resets) {
            Task {
                await reload()
                reset.listRead()
            }
        }
    }
}

@MainActor
enum CostResetControls {
    /// The confirmed «Изтрий всички»: the costs go, the five seconds start
    /// (longer under VoiceOver or Switch Control), and it is said, with the
    /// way back.
    static func confirm(_ reset: CostReset) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        reset.confirm(window: assisted ? TreatmentRemoval.assistedWindow : nil)
        var said = AttributedString(CostReset.announcement(reset.scope))
        said.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(said).post()
    }
}

/// What went, with «Отмени», for the five seconds before it is sent.
private struct CostResetBar: View {
    let reset: CostReset

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CostReset.removedText(reset.scope))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { reset.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}
