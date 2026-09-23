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
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
    }
}
