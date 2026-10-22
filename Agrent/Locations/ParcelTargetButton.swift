import SwiftUI

/// Jumps the map to the next parcel, one press at a time: the web's «Намери
/// моето поле». It's ONE control on every map that has it: Блокове, both
/// parcel steps (#398), and a recorded treatment's map (#399). So it looks
/// and speaks the same everywhere, and each map supplies only what a press
/// does to its own camera.
///
/// Bottom-trailing on each map, because bottom-leading is Apple's
/// attribution, which must not be covered, and because that is where a thumb
/// is.
struct ParcelTargetButton: View {
    /// How many parcels a press cycles through: one says «Центрирай
    /// парцела» rather than promising a next field that doesn't exist.
    let parcelCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // THE FRAME IS INSIDE THE LABEL, and it is a MINIMUM.
            //
            // Outside the label it sized the button while `.font(.title3)`
            // sized the glyph — a scaled font against a fixed box. At an
            // accessibility text size the material circle drew well outside
            // the 44pt frame the hit test used, so a press on the visible
            // ring missed the button and fell through to the map beneath,
            // which has its own tap recogniser.
            //
            // A minimum rather than a fixed size: 44 is the floor Apple asks
            // for, and the control is allowed to grow with the type it
            // contains so the circle and the target stay the same shape.
            Image(systemName: "dot.viewfinder")
                .font(.title3)
                .padding(11)
                .frame(minWidth: 44, minHeight: 44)
                // SOLID, not `.thinMaterial`: over a satellite tile a
                // material is whatever colour the field beneath it is, so the
                // glyph's contrast changed with every pan. The ring is what
                // separates the disc from a pale field in «Слънце», where
                // `Surface.bar` is white.
                .background(Palette.Surface.bar, in: Circle())
                .overlay { Circle().strokeBorder(Palette.Surface.edge, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel(parcelCount == 1 ? "Центрирай парцела" : "Следващ парцел")
        .accessibilityHint(parcelCount == 1
            ? "Центрира картата върху парцела"
            : "Центрира картата върху следващия парцел")
        .accessibilityInputLabels(parcelCount == 1
            ? A11y.spokenNames("Центрирай парцела", "Center parcel")
            : A11y.spokenNames("Следващ парцел", "Next parcel"))
    }
}
