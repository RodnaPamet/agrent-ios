import SwiftUI

/// Where the offers are, on Bulgaria.
///
/// ── Canvas, not MapKit, and for a different reason than the parcel map ──
///
/// The schematic parcel map avoided MapKit because it had to draw with no
/// network. This one avoids it because the geometry is ALREADY the answer:
/// 28 oblast polygons, pre-projected, bundled. A basemap underneath would
/// add tiles nobody needs for a country-level overview and put Apple's
/// rural Bulgarian imagery — the weakness already recorded in ROADMAP —
/// behind a screen that is about regions rather than places.
///
/// ── The markers are REGION CENTROIDS, not locations ──
///
/// The server derives `lat`/`lon` from `regionCode` against the ISO
/// catalogue, so every listing in an oblast sits on the same point. Two
/// offers from opposite ends of Пловдив are one marker, and that is the
/// data rather than a simplification — said on the screen, because a map
/// invites being read as "where", and this one means "which oblast".
struct ExchangeMapView: View {
    let listings: [ExchangeListing]

    @Environment(\.colorSchemeContrast) private var contrast

    private var map: BulgariaMap? { BulgariaMap.bundled() }
    private var regions: [RegionAggregate] { RegionAggregate.group(listings) }
    private var unplaceable: [ExchangeListing] { RegionAggregate.unplaceable(listings) }

    var body: some View {
        List {
            Section {
                if let map {
                    canvas(map)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                } else {
                    // The asset is bundled, so this cannot happen from a
                    // network failure — only from a build that shipped
                    // without it. Says which, rather than "no data".
                    Text("Картата не е налична в това копие на приложението.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Маркерите показват област, не точно местоположение.")
            }

            if regions.isEmpty {
                Section {
                    Text("Няма обяви с посочена област.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("По области") {
                    ForEach(regions) { RegionRow(region: $0) }
                }
            }

            if !unplaceable.isEmpty {
                Section {
                    // Stated, not dropped. A map that silently omits rows
                    // claims a completeness it does not have — and on a
                    // trading board the omitted row might be the offer.
                    RefusalNote(
                        text: Plural.bg(unplaceable.count, "обява без област", "обяви без област")
                            + " не се показват на картата.",
                        icon: "mappin.slash"
                    )
                }
            }
        }
    }

    private func canvas(_ map: BulgariaMap) -> some View {
        Canvas { context, size in
            // Fit the 1000×600 space into whatever the row is, preserving
            // aspect. The geometry is pre-projected, so this is a scale
            // rather than a projection — nothing here can distort the
            // country.
            let scale = min(size.width / map.width, size.height / map.height)
            let dx = (size.width - map.width * scale) / 2
            let dy = (size.height - map.height * scale) / 2
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: dx + p.x * scale, y: dy + p.y * scale)
            }

            let withOffers = Set(regions.map(\.regionCode))
            for oblast in map.oblasti {
                var path = Path()
                path.addLines(oblast.points.map(place))
                path.closeSubpath()
                let active = withOffers.contains(oblast.iso)
                context.fill(
                    path,
                    with: .color(active
                        ? Palette.accent.opacity(contrast == .increased ? 0.45 : 0.28)
                        : Color(.secondarySystemFill))
                )
                context.stroke(
                    path,
                    with: .color(Color(.separator)),
                    lineWidth: contrast == .increased ? 1.2 : 0.7
                )
            }

            // Markers last, so no polygon paints over one.
            for region in regions {
                guard let first = region.listings.first,
                      let lat = first.lat, let lon = first.lon else { continue }
                let centre = place(map.point(lat: lat, lon: lon))
                // Area proportional to count, so two markers of twice the
                // count are twice the ink rather than twice the radius —
                // radius would exaggerate by the square.
                let radius = 5 + sqrt(Double(region.count)) * 3.5
                let rect = CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Palette.accent))
                context.stroke(
                    Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }
        }
        .background(Color(.systemBackground))
        // A Canvas is one opaque rectangle to VoiceOver, and this one's
        // whole content is positional. Each region becomes its own element
        // so the map is navigable rather than merely announced.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Карта на обявите: "
            + Plural.bg(regions.count, "област", "области"))
        .accessibilityChildren {
            ForEach(regions) { region in
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(region.accessibilityText)
            }
        }
    }
}

struct RegionRow: View {
    let region: RegionAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(region.name).font(.headline)
                Spacer(minLength: 8)
                Text(Plural.bg(region.count, "обява", "обяви"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(region.prices, id: \.currency) { price in
                Text(priceText(price)).font(.footnote).foregroundStyle(.secondary)
            }
            if region.isMixedCurrency {
                // NOT averaged across. Two currencies are two figures; one
                // blended number would be a price in no currency at all.
                Text("Обявите са в различни валути и не се сравняват.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(region.accessibilityText)
    }

    private func priceText(_ price: RegionAggregate.CurrencyPrice) -> String {
        let money = { (d: Decimal) in
            d.formatted(.number.precision(.fractionLength(2)).locale(BgDate.locale))
        }
        if price.isSinglePrice {
            return "\(money(price.low)) \(price.currency) / т"
        }
        return "\(money(price.low)) – \(money(price.high)) \(price.currency) / т"
    }
}

extension RegionAggregate {
    /// Spoken as one stop. Prices are named per currency here too — the
    /// rule is about the figure, not about the channel it reaches.
    var accessibilityText: String {
        var parts: [String?] = [name, Plural.bg(count, "обява", "обяви")]
        for price in prices {
            let money = { (d: Decimal) in
                d.formatted(.number.precision(.fractionLength(2)).locale(BgDate.locale))
            }
            parts.append(price.isSinglePrice
                ? "\(money(price.low)) \(price.currency) на тон"
                : "от \(money(price.low)) до \(money(price.high)) \(price.currency) на тон")
        }
        if isMixedCurrency { parts.append("в различни валути") }
        return A11y.sentence(parts)
    }
}
