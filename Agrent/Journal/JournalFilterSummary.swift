import SwiftUI

/// The first row of a filtered Дневник: what the list is narrowed to, and the
/// way back to all of it (#252).
///
/// A filtered diary and the whole one look the same row for row. Without this,
/// «12 записа» under a filter chosen last week would read as the farm's whole
/// record, and the Дневник is the register an inspector reads. The toolbar
/// icon's fill says that a filter is on; this row says which one.
struct JournalFilterSummary: View {
    let filter: JournalFilter
    let clear: () -> Void

    var body: some View {
        let facts = filter.facts()
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.self) { Text($0) }
            }
            .font(.subheadline)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            // One stop for the facts, named as what they are.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.sentence(["Филтри"] + facts))

            Button(action: clear) {
                Text("Изчисти филтрите")
                    // Wrapped at AX sizes, a button's label centres its
                    // lines, and «Изчисти» sat indented above «филтрите».
                    .multilineTextAlignment(.leading)
                    // 44 points tall, the smallest target Apple allows. The
                    // words alone are a line of `.subheadline`.
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .font(.subheadline)
            // Borderless, so only the words clear the filter. In a list row a
            // plain button takes the whole row, and a tap on the facts would
            // throw the filter away.
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
