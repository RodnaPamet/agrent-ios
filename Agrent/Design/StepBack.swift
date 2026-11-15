import SwiftUI

/// «Назад» on a step of a multi-step form (#609, owner 2026-11-15): one step
/// back, everything entered kept. Said in words beside the arrow, because the
/// system's bare arrow was easy to miss next to «Отказ» — and «Отказ» throws
/// the whole entry away.
///
/// Hidden while `disabled` (a save under way), so a save is not left to land
/// on a step that has gone.
struct StepBack: ViewModifier {
    var disabled = false
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Назад", systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(disabled)
                    .accessibilityInputLabels(A11y.spokenNames("Назад", "Back"))
                }
            }
    }
}

extension View {
    func stepBack(disabled: Bool = false) -> some View { modifier(StepBack(disabled: disabled)) }
}
