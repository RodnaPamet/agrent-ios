import SwiftUI

extension View {
    /// Puts the app's page colour behind a scrolling screen.
    ///
    /// TWO MODIFIERS, because a List draws two backgrounds and hiding one
    /// leaves the other. `scrollContentBackground(.hidden)` removes the
    /// scroll view's; the ROW draws its own on top of that and needs
    /// `listRowBackground` — which must sit on the row rather than on the
    /// List, since applied to the List it reaches nothing inside a
    /// `ForEach`. All three of those were found on screen, in that order,
    /// each looking like the fix until the screenshot came back black.
    ///
    /// `pageBackground()` covers the first; `.listRowBackground(
    /// Palette.Surface.page)` on the row covers the second.
    func pageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.Surface.page)
    }

    /// The row half, so call sites do not have to remember the colour.
    func pageRow() -> some View {
        listRowBackground(Palette.Surface.page)
    }
}

extension View {
    /// A solid band pinned to one edge of a screen — what `.background(.bar)`
    /// used to be, without the material. `Surface.bar` behind it, and an
    /// `edge` hairline on the side that faces the content, so the band reads
    /// as separate from what scrolls past it in every arm, «Слънце»
    /// included, where `--bg-default` and the page are both white.
    ///
    /// `hairline` is the side the line goes on: `.top` for a bar at the
    /// bottom of the screen, `.bottom` for one at the top.
    func solidBar(hairline: VerticalEdge) -> some View {
        modifier(SolidBar(hairline: hairline))
    }
}

private struct SolidBar: ViewModifier {
    let hairline: VerticalEdge
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background(Palette.Surface.bar)
            .overlay(alignment: hairline == .top ? .top : .bottom) {
                Palette.Surface.edge
                    .frame(height: 1 / displayScale)
                    .accessibilityHidden(true)
            }
    }
}
