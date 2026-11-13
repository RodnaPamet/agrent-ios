import SwiftUI

/// One post and its replies, oldest first (#2986: a thread reads in the
/// order it was said). The asker marks a question «Решено»; members reply.
struct ChannelThreadView: View {
    let parent: ChannelPost

    @State private var post: ChannelPost
    @State private var replies: [ChannelPost] = []
    @State private var hasMore = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var replying = false
    @State private var people = CurrentUserStore.shared

    init(parent: ChannelPost) {
        self.parent = parent
        _post = State(initialValue: parent)
    }

    /// Only the asker resolves their own question (`CHANNEL_NOT_THE_ASKER`).
    private var mayResolve: Bool {
        post.isQuestion && !post.deleted && people.user?.id == post.authorUserId
    }

    var body: some View {
        List {
            Section { ChannelPostRow(post: post) }.pageRow()
            if mayResolve {
                Section {
                    Button(post.resolvedAt == nil ? "Отбележи като решен" : "Отвори отново") {
                        Task { await toggleResolved() }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityInputLabels(post.resolvedAt == nil
                        ? A11y.spokenNames("Отбележи като решен", "Решено", "Resolved")
                        : A11y.spokenNames("Отвори отново", "Reopen"))
                }
                .pageRow()
            }
            if let failure {
                Section { Text(failure).font(.footnote).foregroundStyle(Palette.error) }.pageRow()
            }
            Section {
                if loaded, replies.isEmpty {
                    Text("Още няма отговори.").font(.subheadline).foregroundStyle(Palette.secondaryText)
                }
                ForEach(replies) { ChannelPostRow(post: $0) }
                if hasMore {
                    Button("Още отговори") { Task { await loadMore() } }
                        .buttonStyle(.borderless)
                        .accessibilityInputLabels(A11y.spokenNames("Още отговори", "More replies"))
                }
            } header: {
                SectionHeader("Отговори")
            }
            .pageRow()
        }
        .pageBackground()
        .inlineTitle(post.isQuestion ? "Въпрос" : "Публикация")
        .toolbar {
            if !post.deleted {
                ScreenAction(title: "Отговори", systemImage: "arrowshape.turn.up.left",
                             spoken: A11y.spokenNames("Отговори", "Reply")) { replying = true }
            }
        }
        .refreshable { await PullToRefresh.bounded { await loadFirst() } }
        .task { await loadFirst() }
        .sheet(isPresented: $replying) {
            ChannelComposer(mode: .reply(postID: post.id)) { Task { await loadFirst() } }
        }
    }

    private func loadFirst() async {
        do {
            let page = try await ChannelsAPI.replies(post.id)
            replies = page.posts
            hasMore = page.hasMore
            failure = nil
        } catch {
            failure = UserMessage.text(for: error)
        }
        loaded = true
    }

    private func loadMore() async {
        guard let newest = replies.last?.createdAt else { return }
        do {
            let page = try await ChannelsAPI.replies(post.id, after: newest)
            let seen = Set(replies.map(\.id))
            replies += page.posts.filter { !seen.contains($0.id) }
            hasMore = page.hasMore
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    private func toggleResolved() async {
        let resolve = post.resolvedAt == nil
        do {
            try await ChannelsAPI.setResolved(post.id, resolve)
            post = ChannelPost(id: post.id, authorUserId: post.authorUserId, body: post.body, kind: post.kind,
                               createdAt: post.createdAt, deleted: post.deleted,
                               resolvedAt: resolve ? Date() : nil, replyCount: post.replyCount, author: post.author)
            failure = nil
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// A new post in a channel, or a reply in a thread.
struct ChannelComposer: View {
    enum Mode {
        case post(channelID: String)
        case reply(postID: String)
    }

    let mode: Mode
    let onSent: () -> Void

    @State private var text = ""
    @State private var asQuestion = false
    @State private var alsoToChannel = false
    @State private var sending = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    // The display-name prompt (agri-saas #2989): nil until the server says.
    @State private var person: PersonName?
    @State private var nameDraft = ""
    @State private var savingName = false
    @State private var nameFailed = false
    /// What became of the prompt in this composer: saved, or skipped.
    @State private var nameOutcome: String?
    @State private var people = CurrentUserStore.shared

    private var nameReady: Bool {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= ChannelWords.nameMax
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { !trimmed.isEmpty && trimmed.count <= ChannelsAPI.maxBody }
    private var isReply: Bool { if case .reply = mode { return true } else { return false } }

    var body: some View {
        NavigationStack {
            PageForm {
                namePrompt
                Section {
                    TextField("Текст", text: $text, prompt: .fieldPrompt(isReply ? "Вашият отговор" : "Какво искате да споделите?"),
                              axis: .vertical)
                        .lineLimit(4...12)
                } footer: {
                    SectionFooter {
                        if let failure {
                            Text(failure).foregroundStyle(Palette.error)
                        } else if let counter = ChannelWords.counter(text) {
                            Text(counter)
                        } else {
                            Text("Публикациите в каналите се виждат от всички стопанства.")
                        }
                    }
                }
                Section {
                    if isReply {
                        Toggle("Изпрати и в канала", isOn: $alsoToChannel)
                    } else {
                        Toggle("Това е въпрос", isOn: $asQuestion)
                    }
                } footer: {
                    SectionFooter(isReply
                        ? "Отговорът се показва и като отделна публикация в канала."
                        : "Въпросът може да бъде отбелязан като решен от вас.")
                }
            }
            .inlineTitle(isReply ? "Отговор" : "Нова публикация")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(sending)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Изпрати") { Task { await send() } }
                        .disabled(!ready || sending)
                        .accessibilityInputLabels(A11y.spokenNames("Изпрати", "Send"))
                }
            }
            .interactiveDismissDisabled(sending || !trimmed.isEmpty)
            .task {
                guard !ChannelNamePrompt.isSkipped(by: people.user?.id) else { return }
                // A failed read asks nothing: the post goes out either way.
                person = try? await ChannelsAPI.profile()
            }
        }
    }

    /// «Как да Ви наричаме?» before posting, while channels would show no
    /// name for this person. Optional (owner, 2026-11-12): «Не сега» posts
    /// with the farm alone. Giving the name publishes it; the hint saying
    /// where it will be seen is that consent, so it always shows.
    @ViewBuilder
    private var namePrompt: some View {
        if let nameOutcome {
            Section {
                Text(nameOutcome).font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
        } else if person?.needsName == true {
            Section {
                TextField(ChannelWords.nameLabel, text: $nameDraft, prompt: .fieldPrompt(ChannelWords.namePlaceholder))
                    .textContentType(.name)
                    .submitLabel(.done)
                HStack {
                    Button(ChannelWords.nameSave) { Task { await saveName() } }
                        .disabled(!nameReady || savingName)
                        .accessibilityInputLabels(A11y.spokenNames(ChannelWords.nameSave, "Save"))
                    Spacer(minLength: 16)
                    Button(ChannelWords.nameSkip) {
                        ChannelNamePrompt.skip(by: people.user?.id)
                        nameOutcome = ChannelWords.nameSkipped
                    }
                    .foregroundStyle(Palette.secondaryText)
                    .disabled(savingName)
                    .accessibilityInputLabels(A11y.spokenNames(ChannelWords.nameSkip, "Not now"))
                }
                .buttonStyle(.borderless)
            } header: {
                SectionHeader(ChannelWords.nameTitle)
            } footer: {
                SectionFooter {
                    Text(ChannelWords.nameHint)
                    if nameFailed {
                        Text(ChannelWords.nameFailed).foregroundStyle(Palette.error)
                    } else if nameDraft.count > ChannelWords.nameMax {
                        Text("\(nameDraft.count) / \(ChannelWords.nameMax)").foregroundStyle(Palette.error)
                    }
                }
            }
        }
    }

    /// The person's own act, from this form only: never from tests, CI or
    /// A11yShots.
    private func saveName() async {
        guard nameReady, !savingName else { return }
        savingName = true
        nameFailed = false
        defer { savingName = false }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await ChannelsAPI.setDisplayName(name)
            person = PersonName(displayName: name, published: true)
            nameOutcome = ChannelWords.nameSaved
        } catch {
            nameFailed = true
        }
    }

    private func send() async {
        guard ready, !sending else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            switch mode {
            case .post(let channelID):
                try await ChannelsAPI.post(channelID, .init(body: trimmed, kind: asQuestion ? "QUESTION" : "POST",
                                                            tenantSlug: FarmPath.openSlug))
            case .reply(let postID):
                try await ChannelsAPI.reply(postID, .init(body: trimmed, alsoToChannel: alsoToChannel,
                                                           tenantSlug: FarmPath.openSlug))
            }
            onSent()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// «Не сега», remembered per account on this phone, so the prompt does not
/// come back with every post. Keyed by the user, so another account here is
/// still asked; a name set on the web makes the server stop asking anyway.
enum ChannelNamePrompt {
    private static func key(_ userID: String) -> String { "channels.namePromptSkipped.\(userID)" }

    static func isSkipped(by userID: String?) -> Bool {
        guard let userID else { return false }
        return UserDefaults.standard.bool(forKey: key(userID))
    }

    static func skip(by userID: String?) {
        guard let userID else { return }
        UserDefaults.standard.set(true, forKey: key(userID))
    }
}
