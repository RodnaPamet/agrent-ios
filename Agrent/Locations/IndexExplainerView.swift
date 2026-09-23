import SwiftUI

/// What a vegetation index measures, and what not to read into it.
///
/// Reached from the bulb beside the acquisition date — the moment a reader
/// is most likely to be asking what they are looking at.
///
/// ── What this does NOT say ──
///
/// Nothing about what to do. These numbers are a cloud-masked composite
/// that can be a fortnight old, and turning that into "spray now" is an
/// agronomic recommendation the app has no standing to make. It explains
/// the measurement and leaves the decision where it belongs.
struct IndexExplainerView: View {
    let index: VegetationIndex

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text(index.detail)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    scale
                    notes
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(index.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Затвори") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        Text(index.explanation)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same ramp the map draws, with its ends named — so the sheet and
    /// the legend under the chart cannot come to mean different things.
    private var scale: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Скала")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            LinearGradient(colors: index.ramp, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            HStack {
                Text(index.lowLabel)
                Spacer()
                Text(index.highLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Скала от \(index.lowLabel.lowercased()) до \(index.highLabel.lowercased())")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Какво да имате предвид")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(VegetationIndex.sharedNotes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
