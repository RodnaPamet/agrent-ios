import SwiftUI

/// «Разходи»'s type chips (#500, owner 2026-11-01: "several types at
/// once"). Each chip turns one type on or off; «Всички» clears the choice.
/// The list, the totals and the graphs all follow it (`CostBreakdown`).
///
/// They WRAP rather than scroll sideways: a horizontal strip hides the types
/// past the edge from anyone who does not think to swipe it, and at the
/// accessibility text sizes that is most of them.
struct CostTypeFilter: View {
    /// The types in the list, biggest first.
    let available: [CostCategory]
    @Binding var chosen: Set<CostCategory>

    var body: some View {
        ChipFlow(spacing: 8) {
            chip("Всички", on: chosen.isEmpty) { chosen = [] }
            ForEach(available, id: \.self) { category in
                chip(category.label, on: chosen.contains(category)) {
                    if chosen.contains(category) { chosen.remove(category) } else { chosen.insert(category) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Видове разходи")
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.onAccent : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
                .background(on ? Palette.accent : Palette.Surface.bar, in: Capsule())
                .overlay { Capsule().strokeBorder(on ? Color.clear : Palette.Surface.edge, lineWidth: 1) }
                // 44 to the finger, whatever the chip draws.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityInputLabels([title])
    }
}

/// Children left to right, wrapping onto a new line when the next would not
/// fit: the chips' layout.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
