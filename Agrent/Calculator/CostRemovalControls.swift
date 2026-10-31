import SwiftUI
import UIKit

/// «Разходи»'s «Изтрий» (#481): the question, the five seconds of «Отмени»
/// under the list, and a refusal said. `CostRemoval` holds the rules; this
/// is where they meet the screen.
///
/// Plain modifier functions, not a `ViewModifier` struct with state, for
/// the reason `taskRemoval` gives: the struct version crashed UIKit's list
/// update the moment «Изтрий» was pressed.
extension View {
    /// The list's side of «Изтрий». `reload` reads the costs and the
    /// calculator again once the server took a delete.
    func costRemoval(
        _ removal: CostRemoval,
        asking: Binding<CostEntry?>,
        confirming: Binding<Bool>,
        reload: @escaping @MainActor () async -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let undoable = removal.undoable { CostUndoBar(removal: removal, undoable: undoable) }
        }
        .alert(CostRemoval.confirmTitle, isPresented: confirming, presenting: asking.wrappedValue) { cost in
            Button(TreatmentRemoval.actionTitle, role: .destructive) { CostRemovalControls.remove(cost, from: removal) }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: { cost in
            Text(CostRemoval.label(cost))
        }
        .alert("Разходът не е изтрит", isPresented: Bindable(removal).showsFailure, presenting: removal.failure) { _ in
            Button("Затвори", role: .cancel) { removal.dismissFailure() }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: removal.deletions) {
            Task {
                await reload()
                removal.listRead()
            }
        }
    }

    /// A row's «Изтрий», for a person who may write. Not a full swipe:
    /// «Изтрий», then the question, then five seconds of «Отмени».
    func costRemovalSwipe(me: CurrentUser?, ask: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if CostRemoval.offered(to: me) {
                Button(role: .destructive, action: ask) {
                    Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            }
        }
    }
}

@MainActor
enum CostRemovalControls {
    /// The confirmed «Изтрий»: the row goes, the five seconds start (longer
    /// under VoiceOver or Switch Control), and it is said, with the way back.
    static func remove(_ cost: CostEntry, from removal: CostRemoval) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        removal.remove(cost, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(CostRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }
}

/// What went, with «Отмени», for the five seconds before it is sent.
private struct CostUndoBar: View {
    let removal: CostRemoval
    let undoable: CostRemoval.Undoable

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CostRemoval.removedText(undoable))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { removal.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}
