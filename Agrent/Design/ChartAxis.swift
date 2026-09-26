import SwiftUI

extension View {
    /// Axis labels stop growing at `.large`.
    ///
    /// ── Measured, not assumed ──
    ///
    /// At AX3 the Тенденции x axis rendered «1 октом18нуар1апр…» — three date
    /// labels overlapping into one unreadable string. A chart axis has a
    /// fixed width that text does not get to negotiate with, so labels that
    /// scale without limit do not become more readable, they become
    /// illegible in a different way.
    ///
    /// ── Why this is not a loss of accessibility ──
    ///
    /// The chart was never the accessible surface. It is one opaque element
    /// to VoiceOver by construction, and the text around it — the legend on
    /// Тенденции, the spoken totals on Табло — carries the numbers and DOES
    /// scale to AX5. Capping the axis makes the chart remain a picture of
    /// the shape; the values live outside it and always did.
    ///
    /// Clamping the whole screen would be the wrong fix: it would shrink the
    /// legend too, which is the part that must grow.
    ///
    /// ── Why it lives here ──
    ///
    /// It was `private` in `TrendsView.swift`, so the dashboard's chart —
    /// built later, by the same hand, on the same axis API — simply did not
    /// have it. A fix that is private to the screen that discovered the
    /// problem is a fix the next screen has to rediscover.
    func axisLabelScaling() -> some View {
        dynamicTypeSize(...DynamicTypeSize.large)
    }
}
