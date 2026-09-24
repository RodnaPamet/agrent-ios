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
