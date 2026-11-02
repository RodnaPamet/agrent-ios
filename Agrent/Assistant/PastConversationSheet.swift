import SwiftUI

/// One past conversation, opened from «Минали разговори» (#525): read, and
/// continued from where it stopped, in the assistant's own sheet.
///
/// The turns are read first (`GET /api/account/assistant-conversations/{id}`,
/// agri-saas #2722), then handed to a store of the sheet's own, so the next
/// question carries this conversation's id (agri-saas #2694) and the
/// assistant answers it as a follow-up. Nothing of it is cached: it is what
/// the person said to the assistant, as personal as messaging.
struct PastConversationSheet: View {
    let conversation: AssistantMemoryAPI.Conversation
    /// A prepared entry chosen in the sheet, for the screen behind it to
    /// open in «Нов запис», as the assistant's button does.
    var open: (TreatmentDraft) -> Void = { _ in }

    @State private var store = AssistantStore()
    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    var body: some View {
        switch phase {
        case .loaded:
            AssistantSheet(store: store, context: nil, open: open)
        case .loading:
            waiting {
                ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task { await load() }
        case .failed(let message):
            waiting {
                ErrorState(message: message) { await load() }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            store.resume(try await AssistantMemoryAPI.pastConversation(conversation.id))
            phase = .loaded
        } catch {
            phase = .failed(UserMessage.text(for: error))
        }
    }

    /// The sheet's frame while there is no transcript yet: its title and a
    /// way out, at the height the assistant's sheet opens at.
    private func waiting(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .pageBackground()
                .inlineTitle(AssistantText.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
