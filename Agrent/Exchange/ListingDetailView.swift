import SwiftUI

struct ListingDetailView: View {
    let listing: ExchangeListing
    @State private var composing = false
    @State private var opener = ListingThreadOpener()
    @State private var openedThread: ConversationRoute?
    @State private var user = CurrentUserStore.shared

    var body: some View {
        List {
            Section {
                LabeledContent("Култура") { Text(CommodityName.canonical(listing.commodity) ?? listing.commodity) }
                LabeledContent("Тип") { Text(listing.kind.label) }
                LabeledContent("Посока") { Text(listing.side.label) }
                if let quantity = listing.quantityTonnes {
                    LabeledContent("Количество") { Text("\(Exchange.tonnes(quantity) ?? quantity) т") }
                }
                if let price = listing.pricePerTonne {
                    LabeledContent("Цена / т") {
                        Text("\(Exchange.money(price) ?? price) \(listing.priceCurrency ?? "")")
                    }
                }
                LabeledContent("Състояние") { Text(listing.status.label) }
            }

            if let region = listing.regionName {
                Section("Регион") {
                    LabeledContent(region) { Text(listing.regionCode ?? "") }
                }
            }

            // Public plaintext by design — sanitised server-side and
            // deliberately not encrypted, because cross-tenant readability is
            // what the marketplace is for. Absent when the seller wrote none.
            if let description = listing.description, !description.isEmpty {
                Section("Описание") { Text(description) }
            }
            if let seller = listing.sellerDisplayName, !seller.isEmpty {
                Section("Продавач") { Text(seller) }
            }

            Section {
                LabeledContent("Публикувана") {
                    Text(BgDate.full(listing.createdAt))
                }
                if let expires = listing.expiresAt {
                    LabeledContent("Валидна до") {
                        Text(BgDate.full(expires))
                    }
                }
            }

            if listing.isOwn {
                Section {
                    Text("Това е ваша обява.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            } else if listing.isActive {
                Section {
                    // «Изпрати», not «Изпрати запитване» — the owner's
                    // wording.
                    //
                    // Worth knowing rather than discovering: this button
                    // OPENS the composer, and the one that actually sends
                    // is `InquiryComposeView`'s own «Изпрати» in the sheet
                    // it presents. So the same word now appears twice in
                    // one flow, on a control that opens and a control that
                    // sends. Asked for deliberately; if it ever reads
                    // wrong, «Запитване» names the destination instead of
                    // promising the action.
                    Button("Изпрати") { composing = true }
                }
            }

            if MessagingPolicy.offersMessageParty(
                isOwn: listing.isOwn, mayWrite: MessagingPolicy.mayWrite(user.user)
            ) {
                messagePartySection
            }
        }
        .inlineTitle(CommodityName.canonical(listing.commodity) ?? listing.commodity)
        .sheet(isPresented: $composing) {
            InquiryComposeView(listing: listing)
        }
        .navigationDestination(item: $openedThread) { route in
            ConversationView(threadID: route.threadID, commodity: listing.commodity)
        }
    }

    /// PARITY GAP 7. «Message the other party», BESIDE the inquiry, as on the
    /// web — the two are different things: an inquiry is one message whose
    /// contact is revealed only if the owner accepts; a conversation reveals
    /// nothing and goes on.
    ///
    /// OUTSIDE `isActive`, deliberately: on a listing that has closed this is
    /// the way back to a conversation that already exists, and the route
    /// applies no status rule.
    ///
    /// ── NOT FIRED ──
    ///
    /// The tap POSTs open-thread, which puts an empty, unread conversation in
    /// the owner's inbox before a word is written. Built, wired, and never
    /// pressed against production.
    private var messagePartySection: some View {
        let label = MessagingPolicy.messagePartyLabel(side: listing.side)
        return Section {
            Button {
                Task {
                    if let id = await opener.open(listingID: listing.id) {
                        openedThread = ConversationRoute(threadID: id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(label.bulgarian)
                    if opener.opening {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(opener.opening)
            .accessibilityInputLabels(A11y.spokenNames(label.bulgarian, label.english))
            if let failure = opener.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Composing and sending an inquiry.
///
/// SHIPS FUNCTIONAL AND UNEXERCISED. Sending creates a production row and
/// emails the seller tenant's admins, so nothing in development or CI may tap
/// this: the owner's decision is that the first real operator send is the
/// first real test. The button works for them; it has never been pressed here.
struct InquiryComposeView: View {
    let listing: ExchangeListing

    @Environment(\.dismiss) private var dismiss
    @State private var composer = InquiryComposer()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(CommodityName.canonical(listing.commodity) ?? listing.commodity).font(.headline)
                    Text(summary(side: listing.side, kind: listing.kind,
                                 quantity: listing.quantityTonnes,
                                 price: listing.pricePerTonne,
                                 currency: listing.priceCurrency))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }

                Section("Съобщение") {
                    TextEditor(text: $composer.message)
                        .frame(minHeight: 120)
                        .disabled(composer.phase != .editing)
                }

                switch composer.phase {
                case .sent:
                    Section {
                        Label("Запитването е изпратено.", systemImage: "checkmark.circle")
                            // 2.22:1 as `.green`. See `Palette.success`.
                            .foregroundStyle(Palette.success)
                        Text("Продавачът ще види контактите ви само ако приеме запитването.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                case .failed(let message):
                    // `.red` is 3.55:1 on a white row; `Palette.error` is
                    // 5.42:1 and is the app's one colour for "this broke".
                    Section { Text(message).foregroundStyle(Palette.error) }
                case .editing, .sending:
                    EmptyView()
                }
            }
            .inlineTitle("Ново запитване")
            .interactiveDismissDisabled(composer.phase == .sending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(composer.phase == .sent ? "Готово" : "Отказ") { dismiss() }
                        // The word changes with the phase, so the name has to.
                        .accessibilityInputLabels(composer.phase == .sent
                            ? A11y.Spoken.done
                            : A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if composer.phase == .sending {
                        ProgressView()
                    } else if composer.phase != .sent {
                        Button("Изпрати") {
                            Task { await composer.send(listingID: listing.id) }
                        }
                        .accessibilityInputLabels(A11y.Spoken.send)
                        .disabled(!composer.canSend)
                    }
                }
            }
        }
    }
}
