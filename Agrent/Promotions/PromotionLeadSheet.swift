import SwiftUI

/// «Поискай оферта» (#528): a message to the supplier, with the person's
/// EXPLICIT consent to share their name and message with them.
///
/// The consent is a tick the person makes, never implied, and it starts
/// unticked on every opening: the sheet is new each time, so nothing of an
/// earlier, cancelled attempt survives into this one. The server records
/// it as the lawfulness of passing the request on (`consentedAt` is NOT
/// NULL) and refuses a request without it.
///
/// OUTWARD-FACING: «Изпрати» reaches a third party. It is never
/// pressed from development, CI or the screenshots; the owner sends the
/// first real one.
struct PromotionLeadSheet: View {
    let promotion: PromotionsAPI.Promotion
    let done: (Outcome) -> Void

    enum Outcome: Equatable {
        case sent
        case alreadySent
        case noLongerRunning
    }

    @State private var message = ""
    @State private var consent = false
    @State private var sending = false
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && consent && !sending }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField(PromotionLeadText.message, text: $message,
                              prompt: .fieldPrompt(PromotionLeadText.placeholder), axis: .vertical)
                        .lineLimit(4...10)
                        .onChange(of: message) { _, now in
                            if now.count > PromotionsAPI.maxMessage {
                                message = String(now.prefix(PromotionsAPI.maxMessage))
                            }
                        }
                } header: {
                    SectionHeader(PromotionLeadText.message)
                } footer: {
                    SectionFooter { Text(PromotionLeadText.description(promotion.company)) }
                }
                Section {
                    Toggle(isOn: $consent) {
                        Text(PromotionLeadText.consent(promotion.company))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityInputLabels(A11y.spokenNames("Съгласен съм", "I agree"))
                    Link(PromotionLeadText.privacy, destination: Config.baseURL.appending(path: "/privacy"))
                        .font(.subheadline)
                        .accessibilityInputLabels(A11y.spokenNames(PromotionLeadText.privacy, "Privacy policy"))
                } footer: {
                    SectionFooter {
                        if let refusal { Text(refusal).foregroundStyle(Palette.error) }
                    }
                }
            }
            // The short title: a supplier's name beside «Изпрати заявка»
            // did not fit (measured, «Поискай…»). The text under the message
            // and the consent both name the supplier.
            .inlineTitle(PromotionsText.ask)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PromotionLeadText.send) { Task { await send() } }
                        .disabled(!canSend)
                        .accessibilityInputLabels(A11y.spokenNames(PromotionLeadText.send, "Изпрати заявка", "Send"))
                }
            }
            .interactiveDismissDisabled(sending || !trimmed.isEmpty)
        }
    }

    private func send() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        refusal = nil
        do {
            try await PromotionsAPI.sendLead(promotionId: promotion.id, message: trimmed)
            finish(.sent)
        } catch let error where PromotionsAPI.isAlreadySent(error) {
            finish(.alreadySent)
        } catch let error where PromotionsAPI.isNoLongerRunning(error) {
            finish(.noLongerRunning)
        } catch {
            refusal = UserMessage.text(for: error)
        }
    }

    private func finish(_ outcome: Outcome) {
        dismiss()
        done(outcome)
    }
}

/// The sheet's words, the web's (`ag.offers.ask`).
enum PromotionLeadText {
    static let message = "Съобщение"
    static let placeholder = "Опишете какво ви е необходимо…"
    static func description(_ company: String) -> String {
        "Опишете какво ви е необходимо. Заявката се записва за \(company)."
    }
    static func consent(_ company: String) -> String {
        "Съгласен съм името и съобщението ми да бъдат споделени с \(company), за да се свържат с мен относно тази оферта."
    }
    static let privacy = "Политика за поверителност"
    /// «Изпрати», not the web's «Изпрати заявка»: beside the title in the
    /// bar the longer one left the title as «Поискай…» (measured).
    static let send = "Изпрати"
}
