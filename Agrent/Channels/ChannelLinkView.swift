import SwiftUI

/// A channel by its id, from a reply push (#584; agri-saas #2987): that
/// post's thread when the link names one and it is among the newest posts,
/// otherwise the channel. A channel gone since the push, or channels switched
/// off, is said in words.
struct ChannelLinkView: View {
    let channelID: String
    let postID: String?
    @State private var state: LoadState<Opened?> = .loading

    struct Opened: Equatable, Sendable {
        let channel: Channel
        let post: ChannelPost?
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorState(message: message) { await load() }
            case .loaded(let opened, _):
                if let opened {
                    if let post = opened.post {
                        ChannelThreadView(parent: post)
                    } else {
                        ChannelFeedView(channel: opened.channel) {}
                    }
                } else {
                    ContentUnavailableView("Каналът не е намерен", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Може вече да не е достъпен."))
                }
            }
        }
        // The feed's posts open their threads on whichever stack this is on.
        .navigationDestination(for: ChannelPost.self) { ChannelThreadView(parent: $0) }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            guard let channel = try await ChannelsAPI.channels().first(where: { $0.id == channelID }) else {
                state = .loaded(nil, .fresh)
                return
            }
            var post: ChannelPost?
            if let postID {
                // Not finding the post still opens its channel.
                let id = channel.id
                post = try? await Self.find(postID) { try await ChannelsAPI.feed(id, before: $0) }
            }
            state = .loaded(Opened(channel: channel, post: post), .fresh)
        } catch {
            state = .failed(UserMessage.text(for: error))
        }
    }

    /// The post among the newest `pages` pages, paging back as the feed does.
    /// The server has no read of one post (#2986), and a reply push is about a
    /// recent one, so a few pages bound the search.
    nonisolated static func find(_ postID: String, pages: Int = 4,
                                 page: @Sendable (Date?) async throws -> ChannelPage) async throws -> ChannelPost? {
        var before: Date?
        for _ in 0..<pages {
            let current = try await page(before)
            if let post = current.posts.first(where: { $0.id == postID }) { return post }
            guard current.hasMore, let oldest = current.posts.last?.createdAt else { return nil }
            before = oldest
        }
        return nil
    }
}
