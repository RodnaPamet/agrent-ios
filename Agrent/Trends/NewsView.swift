import SwiftUI

/// The agricultural news feed.
///
/// A separate screen from Тенденции rather than a section on it, because
/// the web has `/trends` and `/news` as separate surfaces and the two
/// answer different questions — one is a number over time, the other is
/// what happened this week. They share an API prefix and nothing else.
struct NewsView: View {
    @State private var store = NewsStore()
    @State private var choosing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        RoutedStack {
        VStack(spacing: 0) {
            // The search runs on the server, over every stored article
            // (#231) — Return submits, as on Борса's board.
            SearchField(text: $store.query, prompt: NewsTopicsText.searchPrompt) {
                Task { await store.loadFeed() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            // Only once there are topics to show: before that, «Моите теми»
            // would be a switch to an empty choice.
            if store.hasChoices { scopes }
            content
        }
        // The strip above the list — the search field and the topic chips —
        // sits outside it, so the list's `pageBackground()` stops short of
        // it and the sheet's own grey showed through. Painted here, the
        // header reads as one surface with the bar above, as Борса's does.
        .background(Palette.Surface.page)
        .inlineTitle("Новини")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    choosing = true
                } label: {
                    Label("Предпочитания", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("Предпочитания")
                .accessibilityInputLabels(A11y.Spoken.newsPreferences)
            }
        }
        // The topics just chosen are what the feed should now show.
        .sheet(isPresented: $choosing, onDismiss: { Task { await store.loadFeed() } }) {
            NewsPreferencesView(store: store)
        }
        // «Затвори» only when the app menu presented this — see
        // `closeWhenPresentedFromMenu`. As a tab root it had one that did nothing.
        .closeWhenPresentedFromMenu()
        .task { if store.feed.value == nil { await store.start() } }
        }
    }

    /// «Моите теми | Всички» (owner, 2026-10-08): the person's topics, or
    /// everything. It replaces the Пазар / Политика / Общи control: two
    /// filters that both say «Всички» would be one too many.
    ///
    /// «Цени» is prices only, NOT the old Пазар: agri-saas narrowed it on
    /// purpose (#1466), since Пазар's keywords took in the stems реколт,
    /// износ, внос and добив. That news has its own topic since the owner's
    /// word of 2026-10-09 — «Пазар», keyed `trade`, because `market` is
    /// already one of the old category values and one word must not name
    /// two filters. An article that matches no rule carries no tag at all,
    /// and «Всички» is what keeps it reachable.
    private var scopes: some View {
        AdaptiveRow(spacing: 8) {
            scope(.mine, NewsTopicsText.mine, spoken: A11y.Spoken.myTopics)
            scope(.all, NewsTopicsText.all, spoken: A11y.Spoken.allNews)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Показване")
    }

    /// Борса's section chip, pair for pair: `onAccent` on `accent` when
    /// chosen, with a tick as well under Differentiate Without Colour.
    private func scope(_ scope: NewsTopics.Scope, _ label: String, spoken: [String]) -> some View {
        let isSelected = store.scope == scope
        return Button {
            Task { await store.setScope(scope) }
        } label: {
            HStack(spacing: 4) {
                if isSelected && withoutColor {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
                Text(label)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Palette.accent : Palette.Chip.neutralFill, in: Capsule())
            .foregroundStyle(isSelected ? Palette.onAccent : Color.primary)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityInputLabels(spoken)
    }

    @ViewBuilder
    private var content: some View {
        switch store.feed {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.loadFeed() }

        case .loaded:
            if store.items.isEmpty {
                empty
            } else {
                List {
                    ForEach(store.items) { item in
                        row(item)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            // The row's own background, on the page colour as
                            // every list's is — `pageBackground()` below paints
                            // only behind the rows (#164).
                            .pageRow()
                            // The next page when the last row comes into view.
                            .onAppear {
                                if item.id == store.items.last?.id { Task { await store.loadMore() } }
                            }
                    }
                    if store.loadingMore {
                        ProgressView().frame(maxWidth: .infinity).pageRow()
                    }
                }
                .listStyle(.plain)
                .pageBackground()
                .refreshable { await PullToRefresh.bounded { await store.loadFeed() } }
            }
        }
    }

    /// Said for what was asked: a search finding nothing is the 60-day
    /// window, not a fault (contract §6); topics finding nothing points at
    /// «Всички».
    @ViewBuilder
    private var empty: some View {
        if let query = store.appliedQuery {
            let text = NewsTopicsText.nothingFound(query)
            EmptyState(text.title, icon: "magnifyingglass", message: text.message)
        } else if !store.requestedTags.isEmpty {
            EmptyState(NewsTopicsText.nothingForTopics.title, icon: "newspaper",
                       message: NewsTopicsText.nothingForTopics.message)
        } else {
            EmptyState("Няма новини", icon: "newspaper", message: "Няма публикации за момента.")
        }
    }

    /// Source and date — beside each other normally, stacked at
    /// accessibility sizes. The category is not shown any more: the
    /// article's tags under it say what it is about (#231).
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
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source)
                Text(BgDate.dayMonth(item.publishedAt))
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Text(item.source)
                Spacer(minLength: 8)
                Text(BgDate.dayMonth(item.publishedAt))
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
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
                        .foregroundStyle(Palette.secondaryText)
                        // The cap RELAXES at the accessibility sizes. Three
                        // lines of `.footnote` is a readable teaser at the
                        // default; at AX5 three lines is barely a sentence, so
                        // the summary stops summarising anything.
                        .lineLimit(typeSize.isAccessibilitySize ? 8 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Its tags, named by the catalogue (#231); a key the
                // catalogue does not know is left out rather than shown as
                // code. Part of the row's spoken sentence, as written.
                let tags = NewsTopics.labels(item.tags, in: store.catalogue)
                if !tags.isEmpty {
                    AdaptiveRow(spacing: 6) {
                        ForEach(tags) { tag in
                            CategoryChip(text: tag.label,
                                         foreground: Palette.Chip.neutralText,
                                         background: Palette.Chip.neutralFill)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        // The combined name is headline plus summary plus source plus date —
        // far too long to say. The headline is the handle.
        .accessibilityInputLabels([item.title])
        .accessibilityHint("Отваря статията в браузър")
    }
}
