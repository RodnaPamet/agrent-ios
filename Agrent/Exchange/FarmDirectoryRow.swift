import SwiftUI

/// One farm in «Ферми»: its name, its tagline, then where it is and what it
/// grows. Every value is the farm's own, typed on its page.
struct FarmDirectoryRow: View {
    let hit: FarmDirectoryHit

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.displayName).font(.headline)
                if let tagline = hit.tagline {
                    Text(tagline).font(.subheadline)
                }
                if hit.oblast != nil || !hit.crops.isEmpty {
                    MetaRow {
                        if let oblast = hit.oblast { Text(oblast) }
                        if hit.oblast != nil, !hit.crops.isEmpty { MetaSeparator() }
                        if !hit.crops.isEmpty { Text(Self.crops(hit.crops)) }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Where a tap goes: out to a page, not into a screen of the app.
            // Not at accessibility sizes, as `MetaSeparator`'s dot isn't: its
            // column broke the farm's name mid-word at AX5 («Синтетич / но»,
            // A11yShots, 2026-10-15). VoiceOver has the hint either way.
            if !typeSize.isAccessibilitySize {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // One stop, spoken from the values in the order they're printed. The
        // farm's name is what a person would say to Voice Control.
        .accessibleRow(spoken: Self.spoken(hit), saying: [hit.displayName])
    }

    nonisolated static func crops(_ crops: [String]) -> String {
        crops.joined(separator: ", ")
    }

    /// `nonisolated`: a pure function of a `Sendable` value, called by tests.
    nonisolated static func spoken(_ hit: FarmDirectoryHit) -> String {
        A11y.sentence([
            hit.displayName,
            hit.tagline,
            hit.oblast.map { "област \($0)" },
            hit.crops.isEmpty ? nil : "отглежда " + crops(hit.crops),
        ])
    }
}
