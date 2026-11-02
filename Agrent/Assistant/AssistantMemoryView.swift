import SwiftUI

/// «Какво помни асистентът» in Профил (#507, owner 2026-11-01: "see and
/// delete"; the edit is rule 6 of the design they adopted): every point the
/// assistant has learned about this person, across farms. A tap corrects
/// one, a swipe forgets one (five seconds of «Отмени»), and «Изтрий всичко»
/// forgets them all after one question.
struct AssistantMemoryView: View {
    @State private var store = AssistantMemoryStore()
    @State private var editing: AssistantMemoryAPI.Point?
    @State private var confirmingAll = false

    var body: some View {
        content
            .inlineTitle(AssistantMemoryText.title)
            .task { await store.load() }
            .onDisappear { store.flush() }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let point = store.undoable { undoBar(point) }
            }
            .sheet(item: $editing) { point in
                AssistantMemoryEditView(point: point, store: store)
            }
            .confirmationDialog(AssistantMemoryText.forgetAllQuestion, isPresented: $confirmingAll,
                                titleVisibility: .visible) {
                Button(AssistantMemoryText.forgetAll, role: .destructive) {
                    Task { await store.forgetAll() }
                }
                .accessibilityInputLabels(A11y.spokenNames(AssistantMemoryText.forgetAll, "Delete all"))
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: {
                Text(AssistantMemoryText.forgetAllNote)
            }
            .alert(AssistantMemoryText.notForgotten, isPresented: failureShown, presenting: store.failure) { _ in
                Button("Затвори", role: .cancel) { store.failure = nil }
            } message: { failure in
                Text(failure)
            }
    }

    private var failureShown: Binding<Bool> {
        Binding { store.failure != nil } set: { if !$0 { store.failure = nil } }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded where store.points.isEmpty:
            EmptyState(AssistantMemoryText.emptyTitle, icon: "brain", message: AssistantMemoryText.emptyMessage)
        case .loaded:
            List {
                Section {
                    ForEach(store.points) { point in
                        Button { editing = point } label: { row(point) }
                            .buttonStyle(.plain)
                            .accessibilityHint(AssistantMemoryText.editHint)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    forget(point)
                                } label: {
                                    Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                                }
                                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                            }
                            .pageRow()
                    }
                } header: {
                    SectionHeader(AssistantMemoryText.listTitle)
                } footer: {
                    SectionFooter { Text(AssistantMemoryText.listNote) }
                }
                Section {
                    Button(role: .destructive) {
                        confirmingAll = true
                    } label: {
                        Label(AssistantMemoryText.forgetAll, systemImage: "trash")
                            .foregroundStyle(Palette.destructive)
                    }
                    .accessibilityInputLabels(A11y.spokenNames(AssistantMemoryText.forgetAll, "Delete all"))
                }
                .pageRow()
            }
            .listStyle(.insetGrouped)
            .pageBackground()
        }
    }

    private func row(_ point: AssistantMemoryAPI.Point) -> some View {
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

    /// Swiped (VoiceOver lists it among the row's actions): gone from the
    /// list, said with the way back, and forgotten when the window closes,
    /// longer under VoiceOver or Switch Control. No question first, unlike a
    /// register record: one remembered sentence is not a record anyone must
    /// keep, and «Отмени» is there for five seconds.
    private func forget(_ point: AssistantMemoryAPI.Point) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        store.forget(point, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        var said = AttributedString(AssistantMemoryText.forgottenAnnouncement)
        said.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(said).post()
    }

    private func undoBar(_ point: AssistantMemoryAPI.Point) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AssistantMemoryText.forgotten(point))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { store.undo() }
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

/// The screen's words.
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
    static let forgottenAnnouncement = "Забравено. Можете да отмените."
    static let forgetAll = "Изтрий всичко"
    static let forgetAllQuestion = "Да забрави ли асистентът всичко?"
    static let forgetAllNote = "Всичко запомнено ще бъде изтрито и няма да може да бъде върнато."
    static let notForgotten = "Не е изтрито"
}
