import SwiftUI

/// Риск по парцели — each field's vegetation and moisture, from the
/// satellite.
///
/// ── What this screen is careful about ──
///
/// The numbers are spatial MEANS over a parcel's boundary. The satellite
/// overlay on Локации is per-pixel across a whole location. A farmer
/// comparing one bright patch there against a number here will find them
/// different, and both are right — so the number is labelled as an
/// average rather than left to imply a pixel.
///
/// The acquisition date is shown on every row that has one. A false-colour
/// reading with no date is taken as current, and the satellite composite
/// reaches back past cloud cover without saying so. That mistake already
/// happened once on Тенденции, where a price observed in July sat under a
/// chart that looked like today.
struct FarmRiskView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FarmRiskStore()

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let age = store.parcels.freshness?.ageDescription {
                            StaleBanner(age: age)
                        }
                        locationPicker
                    }
                    .background(.bar)
                }
                .navigationTitle("Риск по парцели")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                    }
                }
                .task {
                    if store.locations.value == nil { await store.loadLocations() }
                    if store.parcels.value == nil { await store.loadParcels() }
                    await store.readRisks()
                }
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationPicker: some View {
        if let locations = store.locations.value, locations.count > 1 {
            Picker("Локация", selection: Binding(
                get: { store.selected?.id ?? "" },
                set: { id in
                    if let match = locations.first(where: { $0.id == id }) {
                        Task { await store.select(match) }
                    }
                }
            )) {
                ForEach(locations) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.parcels {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.loadParcels() }

        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Няма парцели",
                icon: "map",
                message: "Тази локация още няма въведени парцели."
            )

        case .loaded(let rows, _):
            List(rows) { row in
                parcelRow(row)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            .listStyle(.plain)
        }
    }

    // MARK: - One parcel

    private func parcelRow(_ row: RiskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and area on one line: both short, each pinned to its
            // own edge, neither able to grow into the other.
            HStack(alignment: .firstTextBaseline) {
                Text(row.parcel.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let area = row.risk?.areaHa ?? row.parcel.areaHa {
                    Text("\(Num.text(area)) ха")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let crop = CommodityName.freeText(row.risk?.cropType ?? row.parcel.cropType) {
                Text(crop).font(.footnote).foregroundStyle(.secondary)
            }

            if let risk = row.risk {
                readings(risk)
            } else if let failure = row.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The parcel is listed before its reading arrives, so the
                // list is complete from the first frame and fills in.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Изчисляване…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func readings(_ risk: ParcelRisk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two chips, stacked rather than side by side: at accessibility
            // sizes two labelled chips on one line reflow independently and
            // fight, which is the failure JournalDetailView documents.
            reading("Зеленина", risk.vegetation, value: risk.ndvi, index: "NDVI")
            reading("Влага", risk.moisture, value: risk.ndmi, index: "NDMI")

            if let reason = risk.absenceReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            acquisition(risk)
        }
    }

    private func reading(
        _ title: String, _ level: RiskLevel, value: Double?, index: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            CategoryChip(
                text: level.label,
                foreground: level.colors.foreground,
                background: level.colors.background
            )

            if let value {
                // Labelled as an average, deliberately. The map overlay is
                // per-pixel over the whole location; this is one number
                // over this parcel's boundary. A farmer comparing a bright
                // patch there against this will find them different, and
                // both are correct.
                Text("\(index) \(Num.text(value)) ср.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// WHEN THE SATELLITE LOOKED, and how long ago.
    ///
    /// Computed from two server timestamps — see `Staleness`. A reading
    /// with no date reads as today's, and the composite reaches back past
    /// cloud cover without saying so.
    @ViewBuilder
    private func acquisition(_ risk: ParcelRisk) -> some View {
        if let date = risk.acquired {
            let days = risk.staleDays ?? 0
            Label(
                days <= 0
                    ? "Заснето днес"
                    : "Заснето на \(BgDate.dayMonth(date)) · преди \(Plural.bg(days, "ден", "дни"))",
                systemImage: "camera.badge.clock"
            )
            .font(.caption)
            .foregroundStyle(days > Staleness.concerning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
