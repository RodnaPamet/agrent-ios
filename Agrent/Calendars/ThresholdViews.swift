import SwiftUI

/// One pest or disease and its threshold per stage (#636), folded to its
/// name: a crop has a dozen, and the page stays readable.
struct ThresholdRow: View {
    let threshold: AgroThresholds.Threshold

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(threshold.levels, id: \.self) { level in
                    VStack(alignment: .leading, spacing: 2) {
                        if let stage = level.stage.bg {
                            Text(stage).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondaryText)
                        }
                        if let text = level.threshold.bg {
                            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = threshold.note?.bg {
                    Text(note).font(.footnote).foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(threshold.title).font(.body)
                Text(ThresholdWords.kind(threshold.kind))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A crop's thresholds on their own page: what «Риск» opens for the crop the
/// parcel's РЕКОЛТИ record names for this year.
struct ThresholdsSheet: View {
    let cropName: String
    let thresholds: [AgroThresholds.Threshold]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(thresholds) { ThresholdRow(threshold: $0).pageRow() }
                } footer: {
                    SectionFooter { Text(ThresholdWords.note) }
                }
            }
            .pageBackground()
            .inlineTitle("\(ThresholdWords.title): \(cropName)")
            .floatingClose { dismiss() }
        }
    }
}
