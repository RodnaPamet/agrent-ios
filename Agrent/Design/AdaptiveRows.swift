import SwiftUI

/// The two row shapes this app repeats in every list, made to survive
/// Dynamic Type instead of each screen solving it again.
///
/// A list row here is almost always the same thing twice over: a headline,
/// then a line of SECONDARY VALUES under it — a chip beside a date, an email
/// beside a session count, a severity beside a due date beside a name. Both
/// levels break the same way when the text gets big, and both were being
/// fixed one screen at a time, with the fix worded slightly differently each
/// time and applied at only one of the two levels.

/// The OUTER row: a headline's companions, side by side while they fit.
///
/// `ViewThatFits` below the accessibility sizes, which is what the journal,
/// task and member rows already did and what was verified on device: at
/// accessibility3 a plain `HStack` squeezed both children until the chip
/// wrapped to three lines AND the date broke mid-word — "септемвр / и".
/// Neither is a wrap; both are a layout that ran out of room and kept going.
///
/// AT THE ACCESSIBILITY SIZES IT IS UNCONDITIONALLY STACKED, rather than left
/// to `ViewThatFits`. Not because the measurement was wrong — it chose the
/// stack there anyway — but because it is a measurement, and `MetaRow` below
/// now makes the inner content NARROWER at exactly those sizes. A narrower
/// child can make the horizontal candidate start fitting again, which would
/// silently undo a verified layout on three screens as a side effect of an
/// unrelated fix. Deciding it from the size rather than from a width means
/// the two changes cannot interact.
struct AdaptiveRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) { content }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: spacing) { content }
                VStack(alignment: .leading, spacing: 6) { content }
            }
        }
    }
}

/// The INNER row: two or three secondary values on one line.
///
/// This is the level that was missed. The outer row learned to stack and the
/// line inside it did not, so at accessibility5 a task row stacked correctly
/// into chip-above-meta and then rendered «просрочена · 14 септември · Иван
/// Петров» as three columns a few characters wide each, with the name
/// truncated to nothing by a `lineLimit(1)` that was reasonable when it had a
/// whole line to itself.
///
/// `AnyLayout` rather than an `if`, so a value keeps its identity when the
/// reader changes text size with the app open and the row re-lays out
/// instead of being rebuilt.
struct MetaRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: spacing))

        layout { content }
    }
}

/// The `·` between two values in a `MetaRow`, which STOPS EXISTING when the
/// row stacks.
///
/// The separator is punctuation for one line. On a stack it becomes a line of
/// its own containing a single dot, which reads as a bullet list with the
/// bullets on the wrong rows. It is decorative either way — every one of
/// these rows builds its spoken label from the values, precisely so VoiceOver
/// never says "middle dot" — so there is nothing to preserve when it goes.
struct MetaSeparator: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !typeSize.isAccessibilitySize {
            Text("·").foregroundStyle(.secondary)
        }
    }
}
