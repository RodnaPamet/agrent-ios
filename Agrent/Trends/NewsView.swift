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
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            categories
            content
        }
        .navigationTitle("Новини")
        .navigationBarTitleDisplayMode(.inline)
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
            }
        }
    }

    private func row(_ item: NewsItem) -> some View {
        Button {
            if let link = item.link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Source and date on one line: both are short and each is
                // pinned to its own edge, so neither can grow into the
                // other. Everything below gets the full width.
                HStack {
                    Text(item.source)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let category = item.categoryLabel {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(category).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(BgDate.dayMonth(item.publishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
