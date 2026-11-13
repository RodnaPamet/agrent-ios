import SwiftUI

/// One personal conversation (#593): the messages, the composer, and a
/// request's «Приеми» / «Откажи».
///
/// Borrows Борса's conversation where it can — ChatKit's engine and bubbles,
/// the same scroll and older-page rules — and leaves out what a listing's
/// thread has and this does not: role, close, block.
///
/// ── NOT FIRED ──
///
/// Built, wired, and never sent. Opening this screen marks the conversation
/// read, which the other person can see; answering a request is final.
/// Nothing here is tapped against production from development.
struct DirectConversationView: View {
    @State private var store: DirectConversationStore
    private let title: String

    @State private var confirmingDecline = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(conversationID: String, title: String?) {
        _store = State(initialValue: DirectConversationStore(conversationID: conversationID))
        self.title = DirectWords.name(title)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .inlineTitle(title)
        .pageBackground()
        .writeFeedback(store.sendFeedback)
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await store.run()
        }
        .onChange(of: store.unavailable) { _, unavailable in
            guard unavailable else { return }
            AccessibilityNotification.Announcement(ConversationAvailability.title).post()
        }
        .alert("Да откажете ли разговора?", isPresented: $confirmingDecline) {
            Button("Откажи разговора", role: .destructive) { Task { await store.respond(accept: false) } }
            Button("Отказ", role: .cancel) {}
        } message: {
            Text("Това е окончателно. Същият човек няма да може да ви пише отново.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.unavailable {
            EmptyState(ConversationAvailability.title, icon: "lock", message: ConversationAvailability.message)
        } else if store.conversation != nil {
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        } else if let failure = store.loadFailure {
            ErrorState(message: failure) { await store.refresh() }
        } else {
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    olderControl
                    if store.messages.isEmpty {
                        RefusalNote(
                            text: store.mayCompose
                                ? DirectWords.firstMessageNote
                                : "Все още няма съобщения.",
                            icon: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                    }
                    ForEach(store.messages) { message in
                        // No «Премахни» in the first version (owner, 2026-11-13).
                        MessageBubble(message: message, mayRetract: false) {}
                            .id(message.id)
                    }
                    notice
                    Color.clear.frame(height: 0).id(Self.end)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.id) { old, new in
                guard new != nil else { return }
                scrollToEnd(proxy, animated: old != nil)
            }
            .onChange(of: store.state) { scrollToEnd(proxy, animated: true) }
        }
    }

    private static let end = "direct-conversation-end"

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// Where the request stands, as the conversation's last line, like
    /// Борса's closed and blocked notes: a state, never red.
    @ViewBuilder
    private var notice: some View {
        if let text = noticeText {
            RefusalNote(text: text, icon: store.state == .declined ? "hand.raised" : "person.badge.clock")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noticeText: String? {
        if store.state == .declined { return DirectWords.declinedNote }
        if store.awaitingMyAnswer { return DirectWords.requestNote }
        if store.waitingForAnswer { return DirectWords.waitingNote }
        return nil
    }

    @ViewBuilder
    private var olderControl: some View {
        if store.conversation?.canLoadOlder == true {
            VStack(alignment: .leading, spacing: 6) {
                if store.loadingOlder {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Зареждане…").font(.footnote).foregroundStyle(Palette.secondaryText)
                    }
                } else {
                    Button("Зареди по-стари съобщения") { Task { await store.loadOlder() } }
                        .frame(minHeight: 44)
                }
                if let failure = store.olderFailure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = store.actionFailure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.awaitingMyAnswer {
                answerButtons
            } else if store.mayCompose {
                ChatComposer(draft: $store.draft, sending: store.sending, canSend: store.canSend,
                             sendFailure: store.sendFailure) {
                    await store.send()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }

    /// Accepting opens the conversation at once; declining asks first,
    /// because it is final.
    private var answerButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { accept; decline }
            VStack(alignment: .leading, spacing: 8) { accept; decline }
        }
        .disabled(store.acting)
    }

    private var accept: some View {
        Button("Приеми") { Task { await store.respond(accept: true) } }
            .prominentButton()
            .accessibilityInputLabels(A11y.spokenNames("Приеми", "Accept"))
    }

    private var decline: some View {
        Button("Откажи", role: .destructive) { confirmingDecline = true }
            .frame(minHeight: 44)
            .accessibilityInputLabels(A11y.spokenNames("Откажи", "Decline"))
    }
}
