import SwiftUI

/// One exchange conversation: its messages, a composer, and the actions on
/// it (agrent-ios#114, PARITY GAP 7).
///
/// ── NOT FIRED ──
///
/// Built, wired, and never sent. Writing to another farm is the owner's act,
/// the same standing decision as `createListing` — and merely OPENING this
/// screen marks the conversation read (the person's own pointer since
/// agri-saas #1323, still a production write). So no real conversation has
/// been opened from development. The screenshot harness
/// photographs this screen only because it runs on the fixture seam (#115):
/// it opens `thr_synthetic_1`, the mark-read POST is answered `501
/// WRITE_REFUSED` before a socket opens, and nothing is tapped after that.
///
/// ── What the web does that this does not ──
///
/// One failed poll does not replace the conversation with a red line; the
/// newest message is scrolled to; scrollback survives a poll; a retract asks
/// first, and its failure says it was the retract; a send whose outcome is
/// unknown says so. Each is recorded in PARITY.md, Gap 7.
struct ConversationView: View {
    @State private var store: ConversationStore

    /// The commodity the row or listing already showed, for the title while
    /// the first page loads. The page's own value wins once it arrives.
    private let initialCommodity: String?

    @State private var user = CurrentUserStore.shared
    @State private var confirmingBlock = false
    @State private var confirmingRetract = false
    @State private var retracting: ExchangeMessage?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(threadID: String, commodity: String? = nil) {
        _store = State(initialValue: ConversationStore(threadID: threadID))
        initialCommodity = commodity
    }

    private var mayWrite: Bool { MessagingPolicy.mayWrite(user.user) }

    private var title: String {
        guard let slug = store.header?.commodity ?? initialCommodity else { return "Разговор" }
        return CommodityName.canonical(slug) ?? slug
    }

    var body: some View {
        // A container that outlives the loading/loaded switch inside it, so
        // the polling task below is not restarted when the first page lands.
        VStack(spacing: 0) {
            content
        }
        .inlineTitle(title)
        .pageBackground()
        .toolbar {
            if mayWrite, store.conversation != nil, hasActions {
                ToolbarItem(placement: .primaryAction) { actionsMenu }
            }
        }
        .writeFeedback(store.sendFeedback)
        // Keyed on whether the app is ACTIVE: the loop starts when the screen
        // appears or the app returns, and is cancelled when either stops. A
        // conversation behind the lock screen is neither polled nor marked.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await store.run()
        }
        // A 404 can arrive on a POLL, under a conversation someone is
        // reading: the list vanishes and VoiceOver's focus goes with it, so
        // the reason is said rather than left to be found.
        .onChange(of: store.unavailable) { _, unavailable in
            guard unavailable else { return }
            AccessibilityNotification.Announcement(ConversationAvailability.title).post()
        }
        .alert(MessagingPolicy.blockTitle, isPresented: $confirmingBlock) {
            Button("Блокирай", role: .destructive) { Task { await store.setBlocked(true) } }
            Button("Отказ", role: .cancel) {}
        } message: {
            // THE CONFIRMATION IS FOR THIS SENTENCE. Since agri-saas #1397
            // a block refuses this one PERSON on every listing of this farm,
            // and not their colleagues — wider than this conversation and
            // narrower than their farm, and the web does it in one tap and
            // says neither. See `MessagingPolicy.blockedNotice`.
            Text(MessagingPolicy.blockConfirmation)
        }
        .alert("Да премахнете ли съобщението?", isPresented: $confirmingRetract,
               presenting: retracting) { message in
            Button("Премахни", role: .destructive) { Task { await store.retract(message) } }
            Button("Отказ", role: .cancel) {}
        } message: { _ in
            Text("Това не може да бъде отменено. И двете страни ще виждат «Съобщението е премахнато».")
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if store.unavailable {
            // NOT the error state: a 404 is the server saying this person
            // may not read it (#1323), and «Опитай пак» would only ask again.
            // A lock, not a warning triangle — a state, never red.
            EmptyState(
                ConversationAvailability.title,
                icon: "lock",
                message: ConversationAvailability.message
            )
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
                            text: mayWrite
                                ? "Все още няма съобщения. Напишете нещо, за да започнете."
                                : "Все още няма съобщения.",
                            icon: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(
                            message: message,
                            mayRetract: mayWrite && message.mayRetract && !store.acting
                        ) {
                            retracting = message
                            confirmingRetract = true
                        }
                        .id(message.id)
                    }
                    notices
                    // The conversation's END — below the notices, so every
                    // scroll to "the newest" also shows what state it is in.
                    Color.clear.frame(height: 0).id(Self.end)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // A conversation opens at its END, and a short one sits at the
            // bottom like every messenger's — iOS 17's one-argument form.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // ON EVERY NEW NEWEST MESSAGE: a reply arriving, a send landing.
            // Not on an older page — that prepends and leaves the newest id
            // alone, so the farmer stays where they were reading.
            //
            // The first animation in this app, so it asks Reduce Motion
            // first: with it on, the list jumps instead of sliding.
            //
            // To `end`, not to the message itself: the notices sit after the
            // newest message, and anchoring the message to the bottom edge
            // would leave the blocked notice just out of sight under the composer.
            .onChange(of: store.messages.last?.id) { old, new in
                guard new != nil else { return }
                scrollToEnd(proxy, animated: old != nil)
            }
            // A notice that APPEARS — the farmer's own «Блокирай» or
            // «Затвори» from the toolbar — is scrolled to, so it is seen and
            // reached next by VoiceOver without hunting down the list.
            .onChange(of: store.blocked) { scrollToEnd(proxy, animated: true) }
            .onChange(of: store.closed) { scrollToEnd(proxy, animated: true) }
        }
    }

    private static let end = "conversation-end"

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// Closed and blocked, as the LAST LINES OF THE CONVERSATION — not pinned
    /// above the composer (agrent-ios#124).
    ///
    /// Pinned, at AX5 the blocked sentence wrapped to seven lines and left
    /// room for one message: the notice was eating the thing it annotates,
    /// and nothing could scroll it away. In the list it scrolls like
    /// everything else, at every size — one layout, not a size switch; at the
    /// default size it still sits right above the composer, because a
    /// conversation opens at its end.
    ///
    /// Why this and not a one-line summary with the full text for VoiceOver:
    /// the house `RefusalNote` is the WHOLE sentence, shown — «why you cannot»
    /// is the part a farmer needs, and a sighted farmer at AX5 is exactly who
    /// would lose it to a truncation. The empty-conversation note already
    /// lives in this list the same way, and a messenger's «You blocked this
    /// contact» is a line in the thread, not a banner.
    ///
    /// Each note is still ONE element with its text as its label, so
    /// VoiceOver reads it after the newest message, and there is no control
    /// in it for Voice Control to lose. A STATE, not an error: never red.
    /// Closed refuses nothing — it only tells the farmer that writing reopens
    /// it.
    @ViewBuilder
    private var notices: some View {
        if store.closed {
            RefusalNote(
                text: mayWrite
                    ? "Този разговор е затворен. Изпращането на съобщение го отваря отново."
                    : "Този разговор е затворен.",
                icon: "checkmark.bubble"
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if store.blocked {
            RefusalNote(text: MessagingPolicy.blockedNotice(role: store.role), icon: "hand.raised")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// An explicit button, not load-on-scroll — the house rule behind
    /// «Покажи още»: a list that grows by itself under a thumb is a list a
    /// farmer loses their place in.
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

    // MARK: - Actions

    private var hasActions: Bool { !store.closed || store.role.ownsListing }

    private var actionsMenu: some View {
        Menu {
            if !store.closed {
                // One tap, no confirmation: the next message from either
                // side reopens it.
                Button {
                    Task { await store.close() }
                } label: {
                    Label("Затвори разговора", systemImage: "checkmark.bubble")
                }
                .accessibilityInputLabels(A11y.Spoken.closeConversation)
            }
            // «Блокирай», not the web's «Блокирай купувача»: the owner of a
            // BUY listing is blocking a SELLER, and this screen cannot tell
            // which.
            if store.role.ownsListing {
                if store.blocked {
                    Button {
                        Task { await store.setBlocked(false) }
                    } label: {
                        Label("Отблокирай", systemImage: "hand.raised.slash")
                    }
                    .accessibilityInputLabels(A11y.Spoken.unblock)
                } else {
                    Button(role: .destructive) {
                        confirmingBlock = true
                    } label: {
                        Label("Блокирай", systemImage: "hand.raised")
                    }
                    .accessibilityInputLabels(A11y.Spoken.block)
                }
            }
        } label: {
            Label("Действия", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Действия")
        .accessibilityInputLabels(A11y.spokenNames("Действия", "Actions"))
        .disabled(store.acting)
    }

    // MARK: - Footer: the composer

    /// Pinned under the messages, on a solid bar (`solidBar`), the house's
    /// place for a bottom-anchored action. It rises with the keyboard.
    ///
    /// Only what answers a tap stays here: a failed action or send is the
    /// reply to something the farmer just did, and is short. The closed and
    /// blocked STATES moved into the list — see `notices`.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = store.actionFailure {
                failureLine(failure)
            }
            if mayWrite {
                composer
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }

    /// ChatKit's composer (agrent-ios#196): the field, Send, the counter and
    /// the farm's message pause. Send is refused here for a block, on top of
    /// ChatKit's own rules — `ConversationStore.canSend`.
    private var composer: some View {
        ChatComposer(
            draft: $store.draft, sending: store.sending, canSend: store.canSend,
            sendFailure: store.sendFailure
        ) {
            await store.send()
        }
    }

    private func failureLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.error)
            .fixedSize(horizontal: false, vertical: true)
    }
}
