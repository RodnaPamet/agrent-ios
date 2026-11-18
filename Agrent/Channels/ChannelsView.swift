import SwiftUI

/// «Канали» (P9.8, #583): the public channels every farm shares, opened
/// from the menu, in a stack of its own. Joined channels first, then the
/// directory by crop, oblast and input.
struct ChannelsView: View {
    @State private var state: LoadState<[Channel]> = .loading
    @State private var unread = ChannelUnreadStore.shared
    /// Search (#614): while anything is typed, results replace the channels.
    @State private var search = ChannelSearch()
    @State private var searchScope: ChannelsAPI.SearchScope = .joined
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The house stack (`RoutedStack`): as a menu sheet it keeps its own
        // path, and a screen inside can push an `AppRoute` — the conversation
        // «Пиши» opens (#596).
        RoutedStack {
            VStack(spacing: 0) {
                // Search (#614): on Return, as Борса and Новини search.
                SearchField(text: $search.needle, prompt: ChannelWords.searchPrompt) {
                    Task { await search.submit() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                content
            }
                .inlineTitle("Канали")
                .navigationDestination(for: Channel.self) { ChannelFeedView(channel: $0) { Task { await load() } } }
                .navigationDestination(for: ChannelPost.self) { ChannelThreadView(parent: $0) }
                .navigationDestination(for: ForYouView.Destination.self) { _ in ForYouView() }
                .navigationDestination(for: ChannelsAPI.SearchHit.self) { hit in
                    ChannelLinkView(channelID: hit.channelId, postID: hit.post.id)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { if state.value == nil { await load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded where search.isActive:
            searchResults
        case .loaded(let channels, _):
            List {
                // «За Вас» first (P9.7, #614): what happened to the person
                // across every channel.
                Section {
                    NavigationLink(value: ForYouView.Destination()) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ChannelWords.forYou).font(.body)
                                Text(ChannelWords.forYouHint).font(.caption).foregroundStyle(Palette.secondaryText)
                            }
                        } icon: {
                            Image(systemName: "at").foregroundStyle(Palette.accent)
                        }
                    }
                    .accessibilityInputLabels(A11y.Spoken.forYou)
                }
                .pageRow()
                ForEach(ChannelWords.sections(channels), id: \.title) { section in
                    Section {
                        ForEach(section.channels) { channel in
                            NavigationLink(value: channel) { row(channel) }
                        }
                    } header: {
                        SectionHeader(section.title)
                    }
                    .pageRow()
                }
            }
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await load() } }
        }
    }

    /// Newest first, under a line saying where it looked and that the order
    /// is by date: there is no "best match" in this product.
    private var searchResults: some View {
        List {
            Picker("Къде", selection: $searchScope) {
                Text(ChannelWords.searchJoined).tag(ChannelsAPI.SearchScope.joined)
                Text(ChannelWords.searchAll).tag(ChannelsAPI.SearchScope.all)
            }
            .pickerStyle(.segmented)
            .onChange(of: searchScope) { Task { await search.choose(searchScope) } }
            .pageRow()
            if search.tooShort {
                Text(ChannelWords.searchTooShort).font(.footnote).foregroundStyle(Palette.secondaryText).pageRow()
            } else if let failure = search.failure, search.hits.isEmpty {
                Text(failure).font(.footnote).foregroundStyle(Palette.error).pageRow()
            } else if search.hits.isEmpty {
                if search.searching {
                    ProgressView().frame(maxWidth: .infinity).pageRow()
                } else if search.applied != nil {
                    Text(ChannelWords.searchNothing).font(.footnote).foregroundStyle(Palette.secondaryText).pageRow()
                }
            } else {
                Section {
                    ForEach(search.hits) { hit in
                        NavigationLink(value: hit) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.channelNameBg)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.accent)
                                ChannelPostRow(post: hit.post)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .onAppear { if hit.id == search.hits.last?.id { Task { await search.loadMore() } } }
                        .pageRow()
                    }
                    if search.searching { ProgressView().frame(maxWidth: .infinity).pageRow() }
                } header: {
                    SectionHeader(ChannelWords.searchHeader(search.applied ?? search.scope))
                }
            }
        }
        .pageBackground()
    }

    private func row(_ channel: Channel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.nameBg).font(.body)
                if let members = ChannelWords.members(channel.memberCount) {
                    Text(members).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if channel.muted == true {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel("Без известия")
            }
            if let unread = unread.count(for: channel), unread > 0 {
                Text("\(unread)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.accent))
                    .accessibilityLabel(Plural.bg(unread, "непрочетена", "непрочетени"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        let epoch = SessionEpoch.current
        do {
            let channels = try await ChannelsAPI.channels()
            state = .loaded(channels, .fresh)
            unread.apply(channels, asOf: epoch)
        } catch {
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
        }
    }
}

/// One channel's feed, newest first, refreshed every 30 seconds while open
/// (the server has no live stream for channels, #2986 §0).
struct ChannelFeedView: View {
    let channel: Channel
    let onMembershipChanged: () -> Void

    @State private var posts: [ChannelPost] = []
    @State private var hasMore = false
    @State private var loaded = false
    /// Set by the first SUCCESSFUL page (#677). `loaded` is set after a
    /// failure too, so keying `hasMore` on it meant a failed first load
    /// followed by a good retry never offered «По-стари публикации».
    @State private var pagedOnce = false
    @State private var failure: String?
    @State private var joined: Bool
    @State private var composing = false
    @State private var confirmingLeave = false
    @State private var changing = false
    /// The newest post this feed has marked read, so a poll that brought
    /// nothing new does not write again.
    @State private var markedThrough: Date?
    @State private var muted: Bool
    /// Said once, right after muting: what it stops, and from when.
    @State private var mutedNote: String?

    static let refresh: Duration = .seconds(30)

    init(channel: Channel, onMembershipChanged: @escaping () -> Void) {
        self.channel = channel
        self.onMembershipChanged = onMembershipChanged
        _joined = State(initialValue: channel.joined)
        _muted = State(initialValue: channel.muted ?? false)
    }

    var body: some View {
        List {
            if !joined || channel.banned {
                Section { membershipNote }.pageRow()
            }
            if let failure {
                Section { Text(failure).font(.footnote).foregroundStyle(Palette.error) }.pageRow()
            }
            if let mutedNote {
                Section {
                    Text(mutedNote).font(.footnote).foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .pageRow()
            }
            if loaded, posts.isEmpty {
                Section {
                    Text("Още няма публикации в този канал.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
                .pageRow()
            }
            Section {
                ForEach(posts) { post in
                    NavigationLink(value: post) { ChannelPostRow(post: post) }
                        .disabled(post.deleted && post.replyCount == 0)
                }
                if hasMore {
                    Button("По-стари публикации") { Task { await loadOlder() } }
                        .buttonStyle(.borderless)
                        .accessibilityInputLabels(A11y.spokenNames("По-стари публикации", "По-стари", "Older posts"))
                }
            }
            .pageRow()
        }
        .pageBackground()
        .inlineTitle(channel.nameBg)
        .toolbar {
            if joined, !channel.banned {
                ToolbarItem(placement: .secondaryAction) {
                    // Pushes for mentions of me and replies to me (#601);
                    // the feed itself is unchanged.
                    Button {
                        Task { await setMuted(!muted) }
                    } label: {
                        Label(muted ? "Включи известията" : "Без известия",
                              systemImage: muted ? "bell" : "bell.slash")
                    }
                    .disabled(changing)
                    .accessibilityInputLabels(muted ? A11y.spokenNames("Включи известията", "Известия", "Unmute")
                                                    : A11y.spokenNames("Без известия", "Заглуши", "Mute"))
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Напусни канала", role: .destructive) { confirmingLeave = true }
                        .accessibilityInputLabels(A11y.spokenNames("Напусни канала", "Напусни", "Leave"))
                }
                ScreenAction(title: "Нова публикация", spoken: A11y.spokenNames("Нова публикация", "Публикация", "New post")) {
                    composing = true
                }
            }
        }
        .refreshable { await PullToRefresh.bounded { await loadNewest() } }
        .task { await loadNewest() }
        // A mention or reply here, said by the live stream (#605).
        .onReceive(NotificationCenter.default.publisher(for: LiveUpdates.frameNotification)) { note in
            guard let frame = note.object as? LiveUpdates.Frame, frame.kind == .channel, frame.id == channel.id else { return }
            Task { await loadNewest() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refresh)
                guard !Task.isCancelled else { return }
                await loadNewest()
            }
        }
        .sheet(isPresented: $composing) {
            ChannelComposer(mode: .post(channelID: channel.id)) { Task { await loadNewest() } }
        }
        .confirmationDialog("Да напуснете ли канала?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Напусни", role: .destructive) { Task { await setJoined(false) } }
                .accessibilityInputLabels(A11y.spokenNames("Напусни", "Leave"))
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text("Публикациите ще останат видими. Ако се присъедините отново, ще започнете отначало.")
        }
    }

    @ViewBuilder
    private var membershipNote: some View {
        if channel.banned {
            Text("Нямате право да публикувате в този канал.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Всеки може да чете канала. За да публикувате, се присъединете.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Присъедини се") { Task { await setJoined(true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(changing)
                    .accessibilityInputLabels(A11y.spokenNames("Присъедини се", "Join"))
            }
        }
    }

    private func loadNewest() async {
        do {
            let page = try await ChannelsAPI.feed(channel.id)
            if ChannelWords.newestLeavesGap(page.posts, pageHasMore: page.hasMore, over: posts) {
                // More than a page arrived since the last read: start again
                // from the newest page, so «По-стари публикации» reads the
                // posts in between instead of leaving a hole (#677).
                posts = page.posts
                hasMore = page.hasMore
            } else {
                posts = ChannelWords.newest(page.posts, over: posts)
                if !pagedOnce { hasMore = page.hasMore }
            }
            pagedOnce = true
            failure = nil
            await markRead()
        } catch {
            failure = UserMessage.text(for: error)
        }
        loaded = true
    }

    /// Reading the feed reads the channel: the cursor moves when the feed
    /// shows something newer than it last marked (#597). A member only; a
    /// failure leaves the badge as it was, for the next open to clear.
    private func markRead() async {
        guard joined, !channel.banned, let newest = posts.first?.createdAt,
              markedThrough.map({ newest > $0 }) ?? true else { return }
        do {
            try await ChannelsAPI.markRead(channel.id)
            markedThrough = newest
            ChannelUnreadStore.shared.markedRead(channel.id)
        } catch {
            // Kept for the next poll.
        }
    }

    private func loadOlder() async {
        guard let oldest = posts.last else { return }
        do {
            let page = try await ChannelsAPI.feed(channel.id, before: oldest.createdAt, beforeID: oldest.id)
            let seen = Set(posts.map(\.id))
            posts += page.posts.filter { !seen.contains($0.id) }
            hasMore = page.hasMore
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    private func setMuted(_ mute: Bool) async {
        changing = true
        defer { changing = false }
        do {
            try await ChannelsAPI.setMuted(channel.id, mute)
            muted = mute
            failure = nil
            mutedNote = mute ? ChannelWords.mutedNote : nil
            onMembershipChanged()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    private func setJoined(_ join: Bool) async {
        changing = true
        defer { changing = false }
        do {
            if join { try await ChannelsAPI.join(channel.id) } else { try await ChannelsAPI.leave(channel.id) }
            joined = join
            onMembershipChanged()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// A post in a feed or a thread: who, when, its kind, the text, its replies.
struct ChannelPostRow: View {
    let post: ChannelPost
    /// The photo or the player itself — on the post's own screen. A feed row
    /// says only that there is one, since a control inside a row that opens
    /// the thread would fight the row's own tap.
    var showsMedia = false
    @State private var people = CurrentUserStore.shared
    /// «Отвори» on a listing card opens the listing on this stack.
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A removed post names nobody (agri-saas #2989 §3): a name above
            // a blank body would read as an accusation. Its time only.
            MetaRow {
                if !post.deleted, let author = ChannelWords.author(post, me: people.user?.id) {
                    Text(author).font(.caption.weight(.semibold))
                    MetaSeparator()
                }
                Text(BgDate.messageTime(post.createdAt)).font(.caption)
            }
            .foregroundStyle(Palette.secondaryText)
            if let badge = ChannelWords.badge(post) {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(post.resolvedAt == nil ? Palette.accent : Palette.success)
            }
            if post.deleted {
                Text(ChannelWords.deleted).font(.subheadline).italic().foregroundStyle(Palette.secondaryText)
            } else if let card = post.card, let drawn = CardFace(card) {
                cardView(drawn)
            } else {
                // An attachment post may have no text (P9.6).
                if !post.body.isEmpty {
                    Text(post.body).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                if let attachment = post.attachment {
                    if showsMedia {
                        ChannelAttachmentView(postID: post.id, attachment: attachment)
                    } else {
                        Label(ChannelWords.attachment(attachment),
                              systemImage: attachment.isVoice ? "waveform" : "photo")
                            .font(.subheadline)
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            if let replies = ChannelWords.replies(post.replyCount) {
                Text(replies).font(.caption).foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// A machine-written card (#629): its kind's heading, the main line, a
    /// detail, and on the post's own screen «Отвори». Not in a feed row,
    /// whose tap opens the thread.
    @ViewBuilder
    private func cardView(_ face: CardFace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(face.heading)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Palette.accent)
            Text(face.line).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(face.details, id: \.self) { detail in
                Text(detail).font(.caption).foregroundStyle(Palette.secondaryText)
            }
            if showsMedia {
                if let link = face.link {
                    Link(ChannelWords.cardOpen, destination: link)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityInputLabels(A11y.spokenNames(ChannelWords.cardOpen, "Open"))
                } else if let listingID = face.listingID {
                    Button(ChannelWords.cardOpen) { pushRoute(.listingID(listingID)) }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityInputLabels(A11y.spokenNames(ChannelWords.cardOpen, "Open"))
                }
            }
        }
    }
}

/// What a card shows, by kind. Nil when the kind is unknown or its facts
/// are missing (the web's rule: NEWS, SCHEME and EVENT need a title,
/// LISTING a commodity and a quantity), and the post shows its body.
struct CardFace: Equatable {
    let heading: String
    let line: String
    let details: [String]
    let link: URL?
    let listingID: String?

    init?(_ card: ChannelPost.Card) {
        if let news = card.news {
            heading = ChannelWords.newsHeading
            line = news.title
            details = [news.source.flatMap { $0.isEmpty ? nil : ChannelWords.newsSource($0) }].compactMap { $0 }
            link = news.link
            listingID = nil
        } else if let listing = card.listing, let text = ChannelWords.listingLine(listing) {
            heading = ChannelWords.listingHeading
            line = text
            details = []
            link = nil
            listingID = listing.listingId
        } else if let scheme = card.scheme {
            heading = ChannelWords.schemeHeading
            line = scheme.title
            details = [scheme.authority, ChannelWords.deadline(scheme.closesOn)].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            link = ChannelPost.Card.webLink(scheme.url)
            listingID = nil
        } else if let event = card.event {
            heading = ChannelWords.eventHeading
            line = event.title
            details = [ChannelWords.eventStart(event.startsAt), event.place].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            link = ChannelPost.Card.webLink(event.url)
            listingID = nil
        } else {
            return nil
        }
    }
}
