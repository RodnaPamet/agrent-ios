import SwiftUI

/// «За Вас» (P9.7, #614; agri-saas #2941): what happened to the person
/// across every channel: mentions, and replies to their posts. Newest
/// first, paged on the oldest item's instant.
///
/// Read-only. A row opens the post's thread through `ChannelLinkView`,
/// which reads the post by id and climbs to its parent, so a reply opens
/// the conversation it belongs to.
///
/// A `channel` frame on the live stream is a mention or a reply, which is
/// exactly what this list shows, so it reads the first page again.
struct ForYouView: View {
    /// What «Канали»'s row pushes: the list has no value of its own.
    struct Destination: Hashable {}

    @State private var state: LoadState<[ChannelsAPI.ActivityItem]> = .loading
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var moreFailed: String?

    var body: some View {
        content
            .inlineTitle(ChannelWords.forYou)
            .navigationDestination(for: ChannelsAPI.ActivityItem.self) { item in
                ChannelLinkView(channelID: item.channelId, postID: item.post.id)
            }
            .task { if state.value == nil { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: LiveUpdates.frameNotification)) { note in
                guard (note.object as? LiveUpdates.Frame)?.kind == .channel else { return }
                Task { await load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let items, _) where items.isEmpty:
            ContentUnavailableView(ChannelWords.forYou, systemImage: "at",
                                   description: Text(ChannelWords.forYouEmpty))
        case .loaded(let items, _):
            List {
                ForEach(items) { item in
                    NavigationLink(value: item) { row(item) }
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                        .pageRow()
                }
                if loadingMore {
                    ProgressView().frame(maxWidth: .infinity).pageRow()
                } else if let moreFailed {
                    Text(moreFailed).font(.footnote).foregroundStyle(Palette.error).pageRow()
                }
            }
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await load() } }
        }
    }

    private func row(_ item: ChannelsAPI.ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ChannelWords.reason(item))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            ChannelPostRow(post: item.post)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            let page = try await ChannelsAPI.activity()
            state = .loaded(page.items, .fresh)
            hasMore = page.hasMore
            moreFailed = nil
        } catch {
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
        }
    }

    private func loadMore() async {
        guard hasMore, !loadingMore, let items = state.value, let oldest = items.last?.post.createdAt else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await ChannelsAPI.activity(before: oldest)
            state = .loaded(ChannelWords.merged(page.items, into: items), .fresh)
            hasMore = page.hasMore
            moreFailed = nil
        } catch {
            moreFailed = UserMessage.text(for: error)
        }
    }
}
