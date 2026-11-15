import SwiftUI

/// «Агрономически календар» (#633): the crops by group for North or South
/// Bulgaria, each with what is due now.
struct AgroCalendarView: View {
    @AppStorage("agroCalendar.region") private var regionKey = AgroRegion.north.rawValue
    private let calendar = AgroCalendar.bundled()

    private var region: AgroRegion { AgroRegion(rawValue: regionKey) ?? .north }

    var body: some View {
        List {
            Picker("Район", selection: $regionKey) {
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
            if let calendar {
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
            } else {
                Text(AgroWords.none).foregroundStyle(Palette.secondaryText).pageRow()
            }
        }
        .pageBackground()
        .inlineTitle(AgroWords.title)
        .navigationDestination(for: AgroCropPage.self) { page in
            if let calendar, let crop = calendar.crops.first(where: { $0.key == page.key }) {
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

    private var sources: [(id: String, label: String, url: String?)] {
        let ids = Set(crop.windows.flatMap { $0.citations.map(\.source) })
        return ids.sorted().compactMap { id in
            calendar.sources[id].map { (id, "\($0.publisher ?? ""): \($0.title)", $0.url) }
        }
    }
}
