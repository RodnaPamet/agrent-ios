import SwiftUI

/// «Разходи»'s type filter (#500), as a DROPDOWN (owner, 2026-11-01: the
/// chips "need to be a dropdown"). Several types at once, as the owner chose
/// first: each type is a tick in the menu, and the menu stays open while
/// they are ticked. «Всички видове» clears them. The list, the totals and the
/// graphs all follow it (`CostBreakdown`).
struct CostTypeFilter: View {
    /// The types in the list, biggest first.
    let available: [CostCategory]
    @Binding var chosen: Set<CostCategory>

    var body: some View {
        Menu {
            Button {
                chosen = []
            } label: {
                if chosen.isEmpty {
                    Label(Self.all, systemImage: "checkmark")
                } else {
                    Text(Self.all)
                }
            }
            Section(titled: "Видове") {
                ForEach(available, id: \.self) { category in
                    Toggle(category.label, isOn: ticked(category))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Several ticks in one visit, rather than one per opening.
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Видове разходи: \(label)")
        .accessibilityHint("Избира кои видове разходи се показват")
        .accessibilityInputLabels(A11y.spokenNames("Видове разходи", "Expense types"))
    }

    static let all = "Всички видове"

    /// «Всички видове», one type's name, two names, or how many.
    var label: String {
        let names = available.filter(chosen.contains).map(\.label)
        switch names.count {
        case 0: return Self.all
        case 1, 2: return names.joined(separator: ", ")
        default: return Plural.bg(names.count, "вид", "вида")
        }
    }

    private func ticked(_ category: CostCategory) -> Binding<Bool> {
        Binding {
            chosen.contains(category)
        } set: { on in
            if on { chosen.insert(category) } else { chosen.remove(category) }
        }
    }
}
