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
    @State private var benchmarks = AgroBenchmarksStore()
    @State private var thresholds = AgroThresholdsStore()

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
        .task { await benchmarks.load() }
        .task { await thresholds.load() }
        .navigationDestination(for: AgroCropPage.self) { page in
            if let calendar = store.state.value, let crop = calendar.crops.first(where: { $0.key == page.key }) {
                AgroCropView(calendar: calendar, crop: crop, region: page.region,
                             benchmarks: benchmarks.state.value,
                             thresholds: thresholds.state.value?.for(crop.commodityCanonical) ?? [])
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

/// One crop: sowing, the main field work and harvest (no citations on screen, owner 2026-11-16).
struct AgroCropView: View {
    let calendar: AgroCalendar
    let crop: AgroCalendar.Crop
    let region: AgroRegion
    /// The national yield and support rate (#638); nil until they load.
    var benchmarks: AgroBenchmarks?
    /// The crop's pests and diseases with their thresholds (#636).
    var thresholds: [AgroThresholds.Threshold] = []

    var body: some View {
        List {
            section(AgroWords.sowing, crop.windows(.sowing, in: region))
            section(AgroWords.works, crop.windows(.fieldwork, in: region))
            section(AgroWords.harvest, crop.windows(.harvest, in: region))
            nationalSection
            thresholdsSection
            costsSection
            Section {
                EmptyView()
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
            if window.kind == .sowing, let band = AgroWords.band(window.band) {
                Text(band).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondaryText)
            }
            if let title = window.title?.bg { Text(title).font(.subheadline.weight(.semibold)) }
            if let seed = window.seedRate { Text(AgroWords.amount(seed)).font(.subheadline) }
            if let depth = window.depth { Text("\(AgroWords.depth) \(AgroWords.amount(depth))").font(.subheadline) }
            if let note = window.note?.bg {
                Text(note).font(.subheadline).foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Agrent's reason on a corrected or added window. МЗХ's own
            // citations are no longer drawn (owner, 2026-11-16: «МЗХ, 2024,
            // стр. N» off the calendar); the data still carries them.
            if let basis = window.basis?.bg {
                Text(AgroWords.corrected(basis))
                    .font(.caption2)
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                SectionFooter { Text(AgroWords.costsNote(year: year(of: costs))) }
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

    /// The country's average yield and the coupled support, where the crop
    /// joins a commodity that has them (#638). The support is euro the server
    /// converted, so it carries the vine card's marker.
    @ViewBuilder
    private var nationalSection: some View {
        let national = benchmarks?.yield(for: crop)
        let rates = benchmarks?.rates(for: crop) ?? []
        if national != nil || !rates.isEmpty {
            Section {
                if let national {
                    figureRow(BenchmarkWords.yieldLabel(national), BenchmarkWords.yieldValue(national))
                }
                ForEach(rates) { rate in
                    if let cents = rate.perDaEurCents {
                        figureRow(BenchmarkWords.rateLabel(rate), BenchmarkWords.perDa(cents))
                    }
                }
            } header: {
                SectionHeader(BenchmarkWords.nationalTitle)
            } footer: {
                // The marker says the euro was converted; only a rate has one.
                SectionFooter {
                    if let rate = rates.first {
                        Text(AgroWords.costsNote(year: String(rate.campaign)))
                    }
                }
            }
            .pageRow()
        }
    }

    /// What to watch for on this crop and when treating pays (#636): the
    /// guide's threshold per stage, shown, never judged.
    @ViewBuilder
    private var thresholdsSection: some View {
        if !thresholds.isEmpty {
            Section {
                ForEach(thresholds) { ThresholdRow(threshold: $0) }
            } header: {
                SectionHeader(ThresholdWords.title)
            } footer: {
                SectionFooter { Text(ThresholdWords.note) }
            }
            .pageRow()
        }
    }

    private func figureRow(_ label: String, _ value: String) -> some View {
        AdaptiveRow(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// The card's year, from its source's `published` («2026-09» → «2026»).
    private func year(of costs: AgroCalendar.Costs) -> String? {
        costs.cite.flatMap { AgroWords.year(calendar.sources[$0.source]?.published) }
    }

}
