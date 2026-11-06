import SwiftUI
import UIKit

/// РЕКОЛТИ's and ПЛЕВЕЛИ's «Изтрий» (#541): the question, the five seconds
/// of «Отмени» under the list, and a refusal said. `HistoryRemoval` holds
/// the rules; this is where they meet the screen.
///
/// Plain modifier functions, not a `ViewModifier` struct with state, for
/// the reason `taskRemoval` gives: the struct version crashed UIKit's list
/// update the moment «Изтрий» was pressed.
extension View {
    /// The list's side of «Изтрий». `reload` reads the archive again once
    /// the server took a delete.
    func historyRemoval(
        _ removal: HistoryRemoval,
        asking: Binding<HistoryRemoval.Target?>,
        confirming: Binding<Bool>,
        reload: @escaping @MainActor () async -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let undoable = removal.undoable { HistoryUndoBar(removal: removal, undoable: undoable) }
        }
        .alert(asking.wrappedValue.map { HistoryRemoval.confirmTitle($0.kind) } ?? "",
               isPresented: confirming, presenting: asking.wrappedValue) { target in
            Button(TreatmentRemoval.actionTitle, role: .destructive) { HistoryRemovalControls.remove(target, from: removal) }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: { target in
            Text(HistoryRemoval.confirmMessage(target))
        }
        .alert(HistoryRemoval.failureTitle, isPresented: Bindable(removal).showsFailure,
               presenting: removal.failure) { _ in
            Button("Затвори", role: .cancel) { removal.dismissFailure() }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: removal.deletions) {
            Task {
                await reload()
                removal.archiveRead()
            }
        }
    }

    /// A row's «Изтрий», for a person who may write. Not a full swipe:
    /// «Изтрий», then the question, then five seconds of «Отмени».
    func historyRemovalSwipe(offered: Bool, ask: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if offered {
                Button(role: .destructive, action: ask) {
                    Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            }
        }
    }
}

@MainActor
enum HistoryRemovalControls {
    /// The confirmed «Изтрий»: the row goes, the five seconds start (longer
    /// under VoiceOver or Switch Control), and it is said, with the way back.
    static func remove(_ target: HistoryRemoval.Target, from removal: HistoryRemoval) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        removal.remove(target, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(HistoryRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }
}

/// What went, with «Отмени», for the five seconds before it is sent.
private struct HistoryUndoBar: View {
    let removal: HistoryRemoval
    let undoable: HistoryRemoval.Target

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(HistoryRemoval.removedText(undoable))
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
