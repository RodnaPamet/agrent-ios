import SwiftUI

/// «Почва» (owner, 2026-11-26): the soil section of the knowledge base, under
/// «Знания» for every role. Seven topics — nitrogen rules, slopes and water,
/// manure, soil analysis, erosion and cover, organic matter and rotation, soil
/// life — each Agrent's own summary of Bulgarian official documents and two
/// free guides, each naming the documents it summarises.
///
/// The server holds the words (`GET /api/t/{farm}/knowledge/soil-guide`), the
/// same module its web page and the assistant's `soil_guide` tool read, so the
/// three cannot disagree. Nothing here is written by the phone.
struct SoilGuide: Decodable, Equatable, Sendable {
    struct Source: Decodable, Equatable, Sendable, Hashable {
        let id: String
        /// The document's own title, Bulgarian.
        let title: String
        let publisher: String
        let year: Int
        let url: String

        /// The full document, when its address is one Safari opens.
        var link: URL? {
            guard let url = URL(string: url), InAppBrowser.opens(url) else { return nil }
            return url
        }
    }

    struct Section: Decodable, Equatable, Sendable, Hashable, Identifiable {
        let id: String
        let title: String
        let summary: String
        /// One self-contained point per entry, in reading order.
        let points: [String]
        let sources: [Source]
    }

    let sections: [Section]
}

enum SoilGuideAPI {
    /// Bulgarian, named rather than left to the server's default, because this
    /// app's every word is Bulgarian whatever the person's web setting.
    static var path: String { "\(FarmPath.root)/knowledge/soil-guide?lang=bg" }

    /// The web page an assistant answer links to; the phone opens this screen
    /// for it instead (`AssistantSheet.follow`).
    static let webPage = "/knowledge/soil"

    static func decode(_ data: Data) async throws -> SoilGuide {
        try await APIClient.shared.decode(data, as: SoilGuide.self)
    }
}

/// The guide, cache first: one small payload, the same for every farm.
@MainActor
@Observable
final class SoilGuideStore {
    private(set) var state: LoadState<SoilGuide> = .loading

    func load() async {
        guard state.value == nil else { return }
        await CachedResource.loadShowingCacheFirst(SoilGuideAPI.path) { data in
            try await SoilGuideAPI.decode(data)
        } publish: { [weak self] answer in
            self?.state = answer
        }
    }

    /// For «Опитай отново»: drop what failed and ask again.
    func reload() async {
        state = .loading
        await load()
    }
}

enum SoilWords {
    static let title = "Почва"
    static let intro = "Какво казват официалните правила и проверени ръководства за торенето, ерозията, почвения анализ и почвения живот — по теми, с източника към всяка."
    static let disclaimer = "Обобщения от Agrent. Преди да действате по дата, отстояние или норма, проверете пълния документ и изискванията за текущата година."
    static let sources = "Източници"

    /// «Министерство на земеделието и храните, 2024».
    static func sourceMeta(_ source: SoilGuide.Source) -> String {
        "\(source.publisher), \(source.year)"
    }
}

/// The topic list.
struct SoilGuideView: View {
    @State private var store = SoilGuideStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RoutedStack {
            List {
                Section {
                    Text(SoilWords.intro)
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
                    ErrorState(message: message) { await store.reload() }
                        .pageRow()
                case .loaded(let guide, _):
                    Section {
                        ForEach(guide.sections) { section in
                            NavigationLink(value: section) { row(section) }
                                .pageRow()
                        }
                    }
                }
            }
            .pageBackground()
            .inlineTitle(SoilWords.title)
            .navigationDestination(for: SoilGuide.Section.self) { SoilSectionView(section: $0).floatingBack() }
            .task { await store.load() }
            .floatingClose { dismiss() }
        }
    }

    private func row(_ section: SoilGuide.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(section.summary)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityInputLabels(A11y.spokenNames(section.title))
    }
}

/// One topic: its points, then the documents it summarises, each opening in
/// Safari's sheet — these are summaries, and a farmer acting on a date or a
/// distance should be able to read the rule itself.
struct SoilSectionView: View {
    let section: SoilGuide.Section
    @State private var page: InAppPage?

    var body: some View {
        List {
            Section {
                Text(section.summary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pageRow()
            Section {
                ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                    Text(point)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .pageRow()
                }
            }
            Section(SoilWords.sources) {
                ForEach(section.sources, id: \.self) { source in
                    sourceRow(source).pageRow()
                }
                Text(SoilWords.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .pageRow()
            }
        }
        .pageBackground()
        .inlineTitle(section.title)
        .sheet(item: $page) { InAppBrowser(url: $0.url).ignoresSafeArea() }
    }

    @ViewBuilder
    private func sourceRow(_ source: SoilGuide.Source) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(source.title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(SoilWords.sourceMeta(source))
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        if let url = source.link {
            Button {
                page = InAppPage(url: url)
            } label: {
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityInputLabels(A11y.spokenNames(source.title))
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}
