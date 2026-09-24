import SwiftUI

/// The agricultural news feed.
///
/// A separate screen from Тенденции rather than a section on it, because
/// the web has `/trends` and `/news` as separate surfaces and the two
/// answer different questions — one is a number over time, the other is
/// what happened this week. They share an API prefix and nothing else.
struct NewsView: View {
    @State private var store = TrendsStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            if let age = store.news.freshness?.ageDescription {
                StaleBanner(age: age)
            }
            categories
            content
        }
        .inlineTitle("Новини")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Затвори") { dismiss() }
            }
        }
        .task { if store.news.value == nil { await store.loadNews() } }
        }
    }

    private var categories: some View {
        Picker("Категория", selection: Binding(
            get: { store.newsCategory },
            set: { new in Task { await store.select(new) } }
        )) {
            ForEach(NewsCategory.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch store.news {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.loadNews() }

        case .loaded(let response, _):
            if response.items.isEmpty {
                EmptyState(
                    "Няма новини",
                    icon: "newspaper",
                    message: "В тази категория няма публикации за момента."
                )
            } else {
                List(response.items) { item in
                    row(item)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
                .listStyle(.plain)
            .scrollContentBackground(.hidden)
            }
        }
    }

    /// Source, category and date — beside each other normally, stacked at
    /// accessibility sizes.
    ///
    /// ── The comment this replaces was wrong ──
    ///
    /// It said: "both are short and each is pinned to its own edge, so
    /// neither can grow into the other." At AX3 they are not short.
    /// `agrovest` broke to «agroves / t» and «23 септември» to
    /// «септемв / ри» — three flexible items on one line reflowing
    /// independently, which is precisely the failure `JournalDetailView`
    /// documents and stacks to avoid. I wrote the avoidance down on one
    /// screen and the defect on another.
    ///
    /// Stacked rather than shrunk, because these ARE the accessible
    /// content — unlike a chart axis, where capping the scale is right
    /// because the numbers live elsewhere. Here there is nowhere else.
    @ViewBuilder
    private func metadata(_ item: NewsItem) -> some View {
        let parts = [item.source, item.categoryLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(parts)
                Text(BgDate.dayMonth(item.publishedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Text(parts)
                Spacer(minLength: 8)
                Text(BgDate.dayMonth(item.publishedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ item: NewsItem) -> some View {
        Button {
            if let link = item.link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                metadata(item)

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = item.cleanedSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Отваря статията в браузър")
    }
}
