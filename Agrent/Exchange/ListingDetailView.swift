import SwiftUI

struct ListingDetailView: View {
    let listing: ExchangeListing
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
            }

            if MessagingPolicy.offersMessageParty(
                isOwn: listing.isOwn, mayWrite: MessagingPolicy.mayWrite(user.user)
            ) {
                messagePartySection
            }
        }
        .inlineTitle(CommodityName.canonical(listing.commodity) ?? listing.commodity)
        .navigationDestination(item: $openedThread) { route in
            ConversationView(threadID: route.threadID, commodity: listing.commodity)
        }
    }

    /// PARITY GAP 7. «Message the other party» — the ONLY action on another
    /// farm's listing. The one-shot inquiry («Изпрати») stood beside it, as on
    /// the web, until the owner removed it on 2026-10-01: a conversation does
    /// everything an inquiry did and goes on, so two buttons offering to
    /// contact the same farm was one too many. Inquiries already sent still
    /// show under «Моите заявки».
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
