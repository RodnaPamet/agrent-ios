import SwiftUI

/// «Области: Плевен, Добрич» with «Изчисти», above the map and the list
/// (#417). The region filter is set on the map and carries to the list, so
/// the list must say it is narrowed — a short board looks exactly like a
/// quiet market otherwise.
struct RegionFilterSummary: View {
    let regions: [String]
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(Self.text(regions), systemImage: "mappin.and.ellipse")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Изчисти", action: onClear)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel("Изчисти областите")
                .accessibilityInputLabels(A11y.Spoken.clearRegions)
        }
    }

    /// In Bulgarian, by `BulgarianRegion`: never the code, never the
    /// server's English.
    static func text(_ regions: [String]) -> String {
        let names = regions.map { BulgarianRegion.name(code: $0) ?? $0 }
        return (names.count == 1 ? "Област: " : "Области: ") + names.joined(separator: ", ")
    }
}
