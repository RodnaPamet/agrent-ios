import SwiftUI

/// The parcels under one ambiguous tap.
struct ParcelChoice: Identifiable {
    let parcels: [Parcel]
    /// Identity is the set that was hit, so tapping the same overlap twice
    /// does not re-present a sheet that is already up.
    var id: String { parcels.map(\.id).joined(separator: "|") }
}

/// Which field did you mean?
///
/// Shown only when a tap lands where two shapes cross — ordinary on the
/// simplified map, where a parcel is drawn as its bounding box and two
/// fields whose true outlines merely touch have rectangles that overlap.
/// The alternative was resolving it by box area, which quietly opened the
/// operation sheet for a field the farmer was not pointing at.
///
/// Every row says enough to tell two neighbouring fields apart: the name,
/// the crop, the area. Name alone is not enough on a farm that numbers
/// several fields alike.
struct ParcelChooser: View {
    let parcels: [Parcel]
    let onPick: (Parcel) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(parcels) { parcel in
                Button {
                    onPick(parcel)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parcel.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            if let crop = CommodityName.freeText(parcel.cropType) { Text(crop) }
                            if let area = parcel.areaHa {
                                if parcel.cropType != nil { Text("·") }
                                Text(Area(hectares: area).text)
                            }
                            if parcel.hasActiveLease == true {
                                Text("·"); Text("под аренда")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                    }
                }
                .accessibilityLabel(A11y.sentence([
                    parcel.name,
                    CommodityName.freeText(parcel.cropType),
                    parcel.areaHa.map { Area(hectares: $0).spoken },
                ]))
            }
            .inlineTitle("Кой парцел?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                }
            }
            // Tall enough to show the overlap without covering the map it
            // is asking about — the farmer may want to look again.
            .presentationDetents([.height(260), .medium])
        }
    }
}
