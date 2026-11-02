import SwiftUI

/// «Какво помни асистентът» in Профил (#507, owner 2026-11-01: "see and
/// delete"; the edit is rule 6 of the design they adopted).
///
/// Two halves, as on the web (agri-saas #2708, #2715), each with its own
/// controls, because they delete different things: «Запомнено», the points
/// the assistant has concluded about the person, which a tap corrects; and
/// «Минали разговори» (#521), the exchanges those came from. A person may
/// forget a conversation and keep the conclusion, or the reverse, so each
/// «Изтрий всички…» says what it leaves.
///
/// One row goes on a swipe, with five seconds of «Отмени»; all of a half go
/// after one question.
struct AssistantMemoryView: View {
    @State private var points = AssistantMemoryStore()
    @State private var conversations = PastConversationsStore()
    @State private var editing: AssistantMemoryAPI.Point?
    @State private var confirmingPoints = false
    @State private var confirmingConversations = false

    var body: some View {
        List {
            // The rows set their own `pageRow()`; said once here too, as
            // every list says it in its closure (`FormSurfaceTests`).
            pointsSection.pageRow()
            conversationsSection.pageRow()
        }
        .listStyle(.insetGrouped)
        .pageBackground()
        .inlineTitle(AssistantMemoryText.title)
        .task {
            async let remembered: Void = points.load()
            async let exchanged: Void = conversations.load()
            _ = await (remembered, exchanged)
        }
        .onDisappear {
            points.flush()
            conversations.flush()
        }
        .refreshable {
            await PullToRefresh.bounded {
                async let remembered: Void = points.load()
                async let exchanged: Void = conversations.load()
                _ = await (remembered, exchanged)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let point = points.undoable {
                    undoBar(AssistantMemoryText.forgotten(point)) { points.undo() }
                }
                if let conversation = conversations.undoable {
                    undoBar(AssistantMemoryText.forgotten(conversation)) { conversations.undo() }
                }
            }
        }
        .sheet(item: $editing) { point in
            AssistantMemoryEditView(point: point, store: points)
        }
        .confirmationDialog(AssistantMemoryText.forgetAllQuestion, isPresented: $confirmingPoints,
                            titleVisibility: .visible) {
            Button(AssistantMemoryText.forgetAll, role: .destructive) {
                Task { await points.forgetAll() }
            }
            .accessibilityInputLabels(A11y.spokenNames(AssistantMemoryText.forgetAll, "Delete all"))
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(AssistantMemoryText.forgetAllNote)
        }
        .confirmationDialog(AssistantMemoryText.forgetAllConversationsQuestion, isPresented: $confirmingConversations,
                            titleVisibility: .visible) {
            Button(AssistantMemoryText.forgetAllConversations, role: .destructive) {
                Task { await conversations.forgetAll() }
            }
            .accessibilityInputLabels(A11y.spokenNames(AssistantMemoryText.forgetAllConversations,
                                                       "Delete all conversations"))
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(AssistantMemoryText.forgetAllConversationsNote)
        }
        .alert(AssistantMemoryText.notForgotten, isPresented: failureShown, presenting: failure) { _ in
            Button("Затвори", role: .cancel) {
                points.failure = nil
                conversations.failure = nil
            }
        } message: { failure in
            Text(failure)
        }
    }

    private var failure: String? { points.failure ?? conversations.failure }

    private var failureShown: Binding<Bool> {
        Binding { failure != nil } set: {
            if !$0 {
                points.failure = nil
                conversations.failure = nil
            }
        }
    }

    // MARK: - «Запомнено»

    @ViewBuilder
    private var pointsSection: some View {
        Section {
            switch points.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).pageRow()
            case .failed(let message):
                failed(message) { await points.load() }
            case .loaded where points.points.isEmpty:
                empty(AssistantMemoryText.emptyTitle, AssistantMemoryText.emptyMessage)
            case .loaded:
                ForEach(points.points) { point in
                    Button { editing = point } label: { pointRow(point) }
                        .buttonStyle(.plain)
                        .accessibilityHint(AssistantMemoryText.editHint)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteButton { forget(point, in: points) }
                        }
                        .pageRow()
                }
                forgetAllButton(AssistantMemoryText.forgetAll) { confirmingPoints = true }
            }
        } header: {
            SectionHeader(AssistantMemoryText.listTitle)
        } footer: {
            SectionFooter { Text(AssistantMemoryText.listNote) }
        }
    }

    private func pointRow(_ point: AssistantMemoryAPI.Point) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let when = point.rememberedAt {
                Text("Запомнено на \(BgDate.rowDay(when))")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: - «Минали разговори»

    @ViewBuilder
    private var conversationsSection: some View {
        Section {
            switch conversations.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).pageRow()
            case .failed(let message):
                failed(message) { await conversations.load() }
            case .loaded where conversations.items.isEmpty:
                empty(AssistantMemoryText.noConversationsTitle, AssistantMemoryText.noConversationsMessage)
            case .loaded:
                ForEach(conversations.items) { conversation in
                    conversationRow(conversation)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteButton { forget(conversation, in: conversations) }
                        }
                        .pageRow()
                }
                forgetAllButton(AssistantMemoryText.forgetAllConversations) { confirmingConversations = true }
            }
        } header: {
            SectionHeader(AssistantMemoryText.conversationsTitle)
        } footer: {
            SectionFooter { Text(AssistantMemoryText.conversationsNote) }
        }
    }

    /// The person's first question, then when and how long. Nothing opens
    /// on a tap: the server serves the list, not an exchange's turns.
    private func conversationRow(_ conversation: AssistantMemoryAPI.Conversation) -> some View {
        let opening = conversation.opening.map { "«\($0)»" } ?? AssistantMemoryText.noOpening
        let turns = Plural.bg(conversation.turns, "реплика", "реплики")
        let when = conversation.lastTurnAt.map { BgDate.rowDay($0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(opening)
                .font(.body)
                .foregroundStyle(conversation.opening == nil ? Palette.secondaryText : .primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            MetaRow {
                if let when {
                    Text(when)
                    MetaSeparator()
                }
                Text(turns)
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([opening, when, turns]))
    }

    // MARK: - Shared rows

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(TreatmentRemoval.actionTitle, systemImage: "trash")
        }
        .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
    }

    private func forgetAllButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: "trash")
                .foregroundStyle(Palette.destructive)
        }
        .accessibilityInputLabels(A11y.spokenNames(title, "Delete all"))
        .pageRow()
    }

    private func empty(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .pageRow()
    }

    private func failed(_ message: String, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
            Button("Опитай пак") { Task { await retry() } }
                .accessibilityInputLabels(A11y.spokenNames("Опитай пак", "Try again"))
        }
        .pageRow()
    }

    /// Swiped (VoiceOver lists it among the row's actions): gone from the
    /// list, said with the way back, and forgotten when the window closes,
    /// longer under VoiceOver or Switch Control. No question first, unlike a
    /// register record: one remembered sentence or one chat is not a record
    /// anyone must keep, and «Отмени» is there for five seconds.
    private func forget<Item>(_ item: Item, in store: ForgettableList<Item>) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        store.forget(item, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        var said = AttributedString(AssistantMemoryText.forgottenAnnouncement)
        said.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(said).post()
    }

    private func undoBar(_ sentence: String, undo: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(sentence)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle, action: undo)
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}

/// Correcting one point: the person's own words, which the server then
/// never rewrites.
private struct AssistantMemoryEditView: View {
    let point: AssistantMemoryAPI.Point
    let store: AssistantMemoryStore

    @State private var text: String
    @State private var saving = false
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    init(point: AssistantMemoryAPI.Point, store: AssistantMemoryStore) {
        self.point = point
        self.store = store
        _text = State(initialValue: point.text)
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField(AssistantMemoryText.editPlaceholder, text: $text,
                              prompt: .fieldPrompt(AssistantMemoryText.editPlaceholder), axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: text) { _, now in
                            if now.count > AssistantMemoryAPI.maxLength {
                                text = String(now.prefix(AssistantMemoryAPI.maxLength))
                            }
                        }
                } footer: {
                    SectionFooter {
                        if let refusal {
                            Text(refusal).foregroundStyle(Palette.error)
                        } else {
                            Text("\(text.count) от \(AssistantMemoryAPI.maxLength) знака. \(AssistantMemoryText.editNote)")
                        }
                    }
                }
            }
            .inlineTitle(AssistantMemoryText.editTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let refusal = await store.edit(point, to: text) {
            self.refusal = refusal
        } else {
            dismiss()
        }
    }
}

/// The screen's words. The conversations' follow the web's (#2715).
enum AssistantMemoryText {
    static let title = "Какво помни асистентът"
    static let listTitle = "Запомнено"
    static let listNote = "Асистентът използва тези неща във всеки отговор. Докоснете, за да поправите, или плъзнете, за да изтриете. Изтритото не се запомня отново от същите думи."
    static let emptyTitle = "Още нищо"
    static let emptyMessage = "Асистентът ще запомня какво му казвате за себе си и за работата си — култури, предпочитания, начин на отговор."
    static let editTitle = "Поправи"
    static let editPlaceholder = "Какво да помни асистентът"
    static let editNote = "Вашите думи — асистентът не ги пренаписва."
    static let editHint = "Отваря за поправка"
    /// The bar names what went, so «Отмени» is a choice about a sentence
    /// the person can read, not about a row that is no longer there.
    static func forgotten(_ point: AssistantMemoryAPI.Point) -> String {
        "Забравено: «\(point.text)»"
    }
    static func forgotten(_ conversation: AssistantMemoryAPI.Conversation) -> String {
        conversation.opening.map { "Разговорът е изтрит: «\($0)»" } ?? "Разговорът е изтрит."
    }
    static let forgottenAnnouncement = "Забравено. Можете да отмените."
    static let forgetAll = "Изтрий всичко запомнено"
    static let forgetAllQuestion = "Да забрави ли асистентът всичко запомнено?"
    static let forgetAllNote = "Всичко запомнено ще бъде изтрито и няма да може да бъде върнато. Минали разговори остават."
    static let notForgotten = "Не е изтрито"

    static let conversationsTitle = "Минали разговори"
    static let conversationsNote = "Всички Ваши разговори с асистента, от всички стопанства. Запазват се, докато съществува профилът Ви, и асистентът може да погледне в тях, когато го попитате за нещо отпреди. Изтриването на разговор не изтрива запомненото от него — то е отделно, по-горе."
    static let noConversationsTitle = "Няма записани разговори"
    static let noConversationsMessage = "Когато разговаряте с асистента, разговорът ще се появи тук и ще можете да го изтриете."
    static let noOpening = "(разговор без въпрос)"
    static let forgetAllConversations = "Изтрий всички разговори"
    static let forgetAllConversationsQuestion = "Да изтрия ли всички разговори?"
    static let forgetAllConversationsNote = "Асистентът ще забрави всички минали разговори и няма да може да поглежда в тях. Това не може да бъде върнато. Запомненото остава."
}
