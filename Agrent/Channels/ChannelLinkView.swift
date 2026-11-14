import SwiftUI

/// A channel by its id, from a reply push (#584; agri-saas #2987): that
/// post's thread when the link names one, otherwise the channel. A channel
/// gone since the push is said in words.
///
/// The post is read by its id (agri-saas #3030); a reply opens its parent's
/// thread, since threads are one level deep. A server without that read falls
/// back to looking among the newest posts.
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
                post = try? await Self.thread(for: postID)
                if post == nil {
                    let id = channel.id
                    post = try? await Self.find(postID) { try await ChannelsAPI.feed(id, before: $0) }
                }
            }
            state = .loaded(Opened(channel: channel, post: post), .fresh)
        } catch {
            state = .failed(UserMessage.text(for: error))
        }
    }

    /// The thread a permalink opens: the post itself, or its parent when the
    /// link names a reply.
    static func thread(for postID: String) async throws -> ChannelPost {
        let found = try await ChannelsAPI.post(postID)
        guard let parent = found.parentPostId else { return found.post }
        return try await ChannelsAPI.post(parent).post
    }

    /// The post among the newest `pages` pages, paging back as the feed does.
    /// The fallback for a server older than agri-saas #3030; a reply push is
    /// about a recent post, so a few pages bound the search.
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
