import SwiftUI

struct ListingDetailView: View {
    let listing: ExchangeListing
    @State private var opener = ListingThreadOpener()
    /// The conversation goes onto Борса's stack as a value once the server
    /// answers with its id (#194) — a push no tap starts directly.
    @Environment(\.pushRoute) private var pushRoute
    /// Whether this listing is still on screen when that answer comes. A
    /// conversation opening after the person has gone back must not land on
    /// whatever they went back to. `navigationDestination(item:)` gave this
    /// for free — its destination left with the listing; a push onto the
    /// stack doesn't.
    @State private var isShown = false
    @State private var user = CurrentUserStore.shared

    var body: some View {
        List {
            // ON THE PAGE, as every list is (#164) — until then this was the
            // system's grouped grey under the app's green bar. `Group` hands
            // `pageRow()` to every section it resolves to, the ones behind an
            // `if` included: one line, as in `PageForm`, rather than seven.
            Group {
                Section {
                    ValueRow("Култура") { Text(CommodityName.canonical(listing.commodity) ?? listing.commodity) }
                    ValueRow("Тип") { Text(listing.kind.label) }
                    ValueRow("Посока") { Text(listing.side.label) }
                    if let quantity = listing.quantityTonnes {
                        ValueRow("Количество") { Text("\(Exchange.tonnes(quantity) ?? quantity) т") }
                    }
                    if let price = listing.pricePerTonne {
                        ValueRow("Цена / т") {
                            Text("\(Exchange.money(price) ?? price) \(listing.priceCurrency ?? "")")
                        }
                    }
                    ValueRow("Състояние") { Text(listing.status.label) }
                }

                if let region = listing.regionName {
                    Section(titled: "Регион") {
                        ValueRow(region) { Text(listing.regionCode ?? "") }
                    }
                }

                // Public plaintext by design — sanitised server-side and
                // deliberately not encrypted, because cross-tenant readability is
                // what the marketplace is for. Absent when the seller wrote none.
                if let description = listing.description, !description.isEmpty {
                    Section(titled: "Описание") { Text(description) }
                }
                if let seller = listing.sellerDisplayName, !seller.isEmpty {
                    Section(titled: "Продавач") { Text(seller) }
                }

                Section {
                    ValueRow("Публикувана") {
                        Text(BgDate.full(listing.createdAt))
                    }
                    if let expires = listing.expiresAt {
                        ValueRow("Валидна до") {
                            Text(BgDate.full(expires))
                        }
                    }
                }

                if listing.isOwn {
                    Section {
                        Text("Това е обява на Вашето стопанство.")
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
            .pageRow()
        }
        .pageBackground()
        .inlineTitle(CommodityName.canonical(listing.commodity) ?? listing.commodity)
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
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
                    if let id = await opener.open(listingID: listing.id), isShown {
                        pushRoute(.conversation(threadID: id, commodity: listing.commodity))
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
