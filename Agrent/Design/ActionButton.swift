import SwiftUI

/// The app's floating action button — one per screen, bottom LEADING.
///
/// ── Why leading, against the platform's habit ──
///
/// iOS puts a floating action where the right thumb falls. This one is on
/// the left, by the owner's instruction, and there is a reason to keep it
/// there beyond the instruction: the parcel map already owns the
/// bottom-trailing corner with «Следващ парцел», and Apple's map
/// attribution owns bottom-leading only on the map itself, where this
/// button does not appear. Putting both controls in the same corner on any
/// screen that grows a second one is how a farmer taps the wrong thing.
///
/// ── One per screen ──
///
/// This is deliberately not a stack or a menu. A floating button that
/// expands into more floating buttons is a menu that has escaped its bar,
/// and the screens here already have a toolbar for secondary actions. If a
/// screen needs two, it needs a toolbar.
struct ActionButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    /// Nil hides the button entirely rather than disabling it — a disabled
    /// floating button is a promise the screen cannot keep, the same rule
    /// the index picker and the target button already follow.
    var isEnabled = true

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if isEnabled {
            Button(action: action) {
                Label(label, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18)
                    // 52, not 44. This floats over content rather than
                    // sitting in a bar, so it is hit while walking, and the
                    // minimum is a floor for controls that hold still.
                    .frame(minHeight: 52)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: Capsule())
                    // The shadow is what separates it from whatever it
                    // floats over — a satellite photograph, in this app,
                    // which can be any colour at all.
                    .shadow(color: .black.opacity(contrast == .increased ? 0.5 : 0.25),
                            radius: 8, y: 3)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .accessibilityLabel(label)
        }
    }
}

extension View {
    /// Floats an `ActionButton` over this view, bottom-leading.
    ///
    /// An overlay rather than a `safeAreaInset`, because the button covers
    /// content by design — a list scrolls under it and the last row stays
    /// reachable by scrolling. An inset would permanently shorten every
    /// screen that has one.
    func actionButton(
        _ label: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .bottomLeading) {
            ActionButton(label: label, systemImage: systemImage,
                         action: action, isEnabled: isEnabled)
        }
    }
}
