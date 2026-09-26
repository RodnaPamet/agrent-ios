import SwiftUI

extension View {
    /// An inline navigation title that Bulgarian does not cut in half.
    ///
    /// `.navigationTitle` sizes its own label, and under a `bg` app language
    /// that size disagrees with what it draws. «Нов разход» — a title this
    /// app ships — renders as «Нов разх…» with two thirds of the bar empty
    /// on either side. Measured on iOS 26.5.
    ///
    /// It is the LANGUAGE rather than the alphabet, and rather than the
    /// width. The same ten characters render whole under `en` and under
    /// `ru`; an eleven-character Latin title, WIDER on screen than the
    /// Bulgarian one that truncates, renders whole; and a twenty-seven
    /// character Bulgarian name renders whole too, because past some length
    /// the bar abandons the centred layout for a wide one and the wrong
    /// measurement stops mattering. What loses is the band in between,
    /// roughly nine to thirteen characters — which is most of the static
    /// titles in this app and most Bulgarian field names.
    ///
    /// Bulgarian is the one language where SF Pro substitutes different
    /// glyph shapes for и, п, д, г and т, which is presumably the seam: the
    /// title is measured before that substitution and drawn after it. That
    /// part is inference. The truncation is not — it is in the screenshots.
    ///
    /// A principal item is laid out against the bar's real width instead, so
    /// the whole title shows, and a name that genuinely does not fit still
    /// truncates, at the bar's edge rather than a third of the way in.
    ///
    /// `.navigationTitle` STAYS. The back button of anything pushed on top
    /// of this screen reads it, VoiceOver announces it, and dropping it for
    /// the principal item would trade a visible bug for two invisible ones.
    func inlineTitle(_ title: String) -> some View {
        modifier(InlineTitleModifier(title: title))
    }
}

/// A MODIFIER RATHER THAN A PLAIN EXTENSION, so it can read the environment.
///
/// `inlineTitle` was a `View` extension and could not see `dynamicTypeSize` —
/// which is why the principal item was pinned to one line for everyone. A
/// `ViewModifier` is the smallest thing that has an environment of its own.
struct InlineTitleModifier: ViewModifier {
    let title: String

    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        // TWO LINES AT THE ACCESSIBILITY SIZES, one otherwise.
                        //
                        // This shim is on 24 screens, and on most the title is
                        // a short fixed word — «Табло», «Новини» — where one
                        // line is right and wrapping would be worse. Some carry
                        // DATA though: a location's name, a parcel's, a task's
                        // reference. At AX3 and above those cut, and the bar is
                        // exactly where a farmer looks to confirm which field
                        // they are on.
                        //
                        // `BulgarianLayout` fixes the MIS-MEASUREMENT defect
                        // that truncated these at ordinary sizes. Genuine width
                        // pressure at triple text size is a different problem
                        // and it needs room, not a fix.
                        //
                        // Capped at two rather than unbounded: a bar that grows
                        // without limit pushes the content off screen, which is
                        // a worse failure than a clipped word.
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                }
            }
    }
}
