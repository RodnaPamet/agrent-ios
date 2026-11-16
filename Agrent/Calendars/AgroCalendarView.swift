import SwiftUI

/// «Агрономически календар» (#633): the crops by group for North or South
/// Bulgaria, each with what is due now.
struct AgroCalendarView: View {
    @AppStorage("agroCalendar.region") private var regionKey = AgroRegion.north.rawValue
    /// Set once the farmer picks a half themselves: from then on their choice
    /// stands, and the blocks no longer move the picker (owner, 2026-11-16).
    @AppStorage("agroCalendar.regionChosen") private var regionChosen = false
    @State private var store = AgroCalendarStore()
    @State private var locations = LocationsStore()

    private var region: AgroRegion { AgroRegion(rawValue: regionKey) ?? .north }

    var body: some View {
        List {
            Picker("Район", selection: Binding(get: { regionKey }, set: {
                regionKey = $0
                regionChosen = true
            })) {
                ForEach(AgroRegion.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .pageRow()
            Section {
                Text(AgroWords.notice)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pageRow()
            switch store.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .pageRow()
            case .failed(let message):
                ErrorState(message: message) { await store.load(region) }
                    .pageRow()
            case .loaded(let calendar, _):
                ForEach(AgroGroup.allCases) { group in
                    let crops = calendar.crops(in: group)
                    if !crops.isEmpty {
                        Section {
                            ForEach(crops) { crop in
                                NavigationLink(value: AgroCropPage(key: crop.key, region: region)) {
                                    row(crop)
                                }
                                .pageRow()
                            }
                        } header: {
                            SectionHeader(group.title)
                        }
                    }
                }
            }
        }
        .pageBackground()
        .inlineTitle(AgroWords.title)
        // Until the farmer has picked, open on the half the farm's blocks lie
        // in, from the cached block list (agri-saas #3100). No farm open, no
        // agreement, or a failure: the picker stays as it is.
        .task {
            guard !regionChosen, FarmPath.openSlug != nil else { return }
            await locations.load()
            if !regionChosen, let blocks = locations.state.value, let half = AgroRegion.of(blocks) {
                regionKey = half.rawValue
            }
        }
        .task(id: region) { await store.load(region) }
        .navigationDestination(for: AgroCropPage.self) { page in
            if let calendar = store.state.value, let crop = calendar.crops.first(where: { $0.key == page.key }) {
                AgroCropView(calendar: calendar, crop: crop, region: page.region)
            }
        }
    }

    private func row(_ crop: AgroCalendar.Crop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(crop.title).font(.body)
            if let now = AgroWords.now(crop, in: region) {
                Text(now).font(.caption).foregroundStyle(Palette.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What a crop row pushes.
struct AgroCropPage: Hashable {
    let key: String
    let region: AgroRegion
}

/// One crop: sowing, the main field work, harvest, and the sources.
struct AgroCropView: View {
    let calendar: AgroCalendar
    let crop: AgroCalendar.Crop
    let region: AgroRegion

    var body: some View {
        List {
            section(AgroWords.sowing, crop.windows(.sowing, in: region))
            section(AgroWords.works, crop.windows(.fieldwork, in: region))
            section(AgroWords.harvest, crop.windows(.harvest, in: region))
            costsSection
            Section {
                ForEach(sources, id: \.id) { source in
                    if let url = source.url.flatMap(URL.init(string:)) {
                        Link(source.label, destination: url).font(.footnote)
                    } else {
                        Text(source.label).font(.footnote)
                    }
                }
            } header: {
                SectionHeader(AgroWords.sources)
            } footer: {
                SectionFooter { Text(AgroWords.notice) }
            }
            .pageRow()
        }
        .pageBackground()
        .inlineTitle("\(crop.title), \(region.short)")
    }

    @ViewBuilder
    private func section(_ title: String, _ windows: [AgroCalendar.Window]) -> some View {
        if !windows.isEmpty {
            Section {
                ForEach(windows) { window in
                    windowRow(window).pageRow()
                }
            } header: {
                SectionHeader(title)
            }
        }
    }

    private func windowRow(_ window: AgroCalendar.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let span = AgroWords.span(window.from, window.to) {
                HStack(alignment: .firstTextBaseline) {
                    Text(span).font(.body.weight(.semibold))
                    if AgroWords.isNow(window.from, window.to) {
                        Text(AgroWords.nowBadge)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            if let title = window.title?.bg { Text(title).font(.subheadline.weight(.semibold)) }
            if let seed = window.seedRate { Text(AgroWords.amount(seed)).font(.subheadline) }
            if let depth = window.depth { Text("\(AgroWords.depth) \(AgroWords.amount(depth))").font(.subheadline) }
            if let note = window.note?.bg {
                Text(note).font(.subheadline).foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(window.citations.compactMap { AgroWords.cite($0, in: calendar) }.joined(separator: "; "))
                .font(.caption2)
                .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    /// МЗХ's direct costs per дка, where МЗХ prices the card (#637): euro
    /// only, as the server converted them, under the owner's marker and the
    /// card's page. A line the server could not convert is left out.
    @ViewBuilder
    private var costsSection: some View {
        if let costs = crop.costs, let total = costs.perDaEurCentsTotal {
            Section {
                ForEach(costs.lines, id: \.key) { line in
                    if let cents = line.perDaEurCents, let label = AgroWords.costLabels[line.key] {
                        costRow(label, cents)
                    }
                }
                costRow(AgroWords.costTotal, total, bold: true)
            } header: {
                SectionHeader(AgroWords.costsTitle)
            } footer: {
                SectionFooter {
                    Text(([AgroWords.costsNote(year: year(of: costs))]
                          + [AgroWords.cite(costs.cite, in: calendar)].compactMap { $0 }).joined(separator: "; "))
                }
            }
            .pageRow()
        }
    }

    private func costRow(_ label: String, _ cents: Int, bold: Bool = false) -> some View {
        AdaptiveRow(spacing: 8) {
            Text(label).font(bold ? .body.weight(.semibold) : .body)
            Spacer(minLength: 8)
            Text(AgroWords.perDa(cents)).font(bold ? .body.weight(.semibold) : .body).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// The card's year, from its source's `published` («2026-09» → «2026»).
    private func year(of costs: AgroCalendar.Costs) -> String? {
        AgroWords.year(calendar.sources[costs.cite.source]?.published)
    }

    private var sources: [(id: String, label: String, url: String?)] {
        let ids = Set(crop.windows.flatMap { $0.citations.map(\.source) })
        return ids.sorted().compactMap { id in
            calendar.sources[id].map { (id, "\($0.publisher ?? ""): \($0.title)", $0.url) }
        }
    }
}
