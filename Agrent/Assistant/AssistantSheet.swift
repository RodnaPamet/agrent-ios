import SwiftUI

/// The assistant's conversation (#483), over the screen it was opened from:
/// half the screen at first, so the screen stays in view, as inflect's
/// drawer leaves its page in place.
///
/// It does not drive the app: no navigation and no form filling on the
/// person's behalf in phase 1. The answer is text; a link in it is kept as
/// text, because a web page path opens nothing here.
struct AssistantSheet: View {
    let store: AssistantStore
    let context: AssistantPageContext?
    /// A prepared entry the person chose to open: the launcher closes this
    /// sheet and opens «Нов запис» with it (#483 phase 2).
    var open: (TreatmentDraft) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    /// The sheet's own bars: the composer's must not lift the button on the
    /// screen behind it.
    @State private var ownChrome = BottomChrome()
    @Environment(AppRouter.self) private var router: AppRouter?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.turns.isEmpty {
                            Text(AssistantText.intro)
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(store.turns) { turn in
                            AssistantTurnView(turn: turn, follow: follow, open: open).id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.turns) {
                    guard let last = store.turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .pageBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .inlineTitle(AssistantText.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Затвори") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.close)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(ownChrome)
        .onDisappear { store.stop() }
    }

    /// A link the person tapped, with the sheet closed: its bar tab, or
    /// the one record it names, opened as a notification's link opens it.
    private func follow(_ link: AssistantLink) {
        guard let router else { return }
        if let surface = link.surface, router.bar.contains(surface) {
            dismiss()
            router.tab = surface
        } else if let screen = link.screen(inFarm: FarmPath.openSlug) {
            dismiss()
            router.open(screen)
        }
    }

    /// The links this phone can follow from here: a bar tab, or a record
    /// it has a screen for. A menu-only page is not offered yet.
    static func followable(_ links: [AssistantLink], bar: [AppSurface], farm: String?) -> [AssistantLink] {
        links.filter { link in
            if let surface = link.surface { return bar.contains(surface) }
            return link.screen(inFarm: farm) != nil
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerField(title: "Въпрос", prompt: AssistantText.prompt,
                          text: Bindable(store).draft)
            Button {
                store.send(context: context)
            } label: {
                Group {
                    if store.asking {
                        ProgressView()
                    } else {
                        Label("Попитай", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(!store.canSend)
            .accessibilityLabel("Попитай")
            .accessibilityInputLabels(A11y.spokenNames("Попитай", "Изпрати", "Ask"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }
}

/// One question and what came of it.
private struct AssistantTurnView: View {
    let turn: AssistantStore.Turn
    let follow: (AssistantLink) -> Void
    let open: (TreatmentDraft) -> Void
    @State private var people = CurrentUserStore.shared
    @Environment(AppRouter.self) private var router: AppRouter?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The question, on the right, as a sent message is.
            Text(turn.question)
                .font(.body)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Вие: \(turn.question)")

            switch turn.phase {
            case .working(let status):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(status).foregroundStyle(Palette.secondaryText)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            case .answered(let text, let links, let note, let proposal):
                Text(AssistantRendering.answer(text))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    // The words as shown: the raw text's Markdown marks would
                    // be read out.
                    .accessibilityLabel(AssistantText.answered(String(AssistantRendering.answer(text).characters)))
                ForEach(AssistantSheet.followable(links, bar: router?.bar ?? [], farm: FarmPath.openSlug),
                        id: \.self) { link in
                    Button {
                        follow(link)
                    } label: {
                        Label(link.label, systemImage: "arrow.right.circle")
                            .font(.subheadline.weight(.medium))
                    }
                    .accessibilityInputLabels(A11y.spokenNames(link.label))
                }
                // A prepared entry (owner, 2026-10-31): the usual form,
                // filled, for the person to check and send. Only for someone
                // who may write, and only a draft this phone has a form for.
                if let entry = proposal?.entry(), people.user?.mayWrite ?? false {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            open(entry)
                        } label: {
                            Label(AssistantText.openEntry, systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityInputLabels(A11y.spokenNames(AssistantText.openEntry, "Нов запис"))
                        Text(AssistantText.preparedNote)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unanswered(let sentence):
                Label(sentence, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The model's answer as the sheet shows it: its inline Markdown (bold, a
/// list's words) kept, its links kept as their words. A link here would be
/// a web page path, which opens nothing in the app; phase 2 brings the
/// screens it means.
enum AssistantRendering {
    static func answer(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var rendered = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in rendered.runs where run.link != nil {
            rendered[run.range].link = nil
        }
        return rendered
    }
}
