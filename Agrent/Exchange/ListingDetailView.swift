import SwiftUI

struct ListingDetailView: View {
    let listing: ExchangeListing
    /// Its status, and «Оттегли» / «Изпълнена» on your own (#478).
    @State private var custody: ListingCustody
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
    @State private var flags = FeatureFlags.shared
    /// The seller's farm page, while it's open.
    @State private var farmPage: InAppPage?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(listing: ExchangeListing) {
        self.listing = listing
        _custody = State(initialValue: ListingCustody(status: listing.status))
    }

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
                    ValueRow("Състояние") { Text(custody.status.label) }
                }

                if let region = listing.region {
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
                    Section(titled: "Продавач") {
                        Text(seller)
                        // A listing published as the farm (P6.7): the name is
                        // the farm's verified one, and its page opens here as
                        // «Ферми» opens it. Behind the same flag, because
                        // `/f/` answers only while the flag is on.
                        if flags.isOn(FarmBrandAPI.flag), let page = InAppPage.farm(handle: listing.farmHandle) {
                            Button {
                                farmPage = page
                            } label: {
                                // Without its icon and with soft hyphens at the
                                // accessibility sizes: AX5 broke «Страница / та»
                                // beside the icon and «стопанство / то» without it.
                                if typeSize.isAccessibilitySize {
                                    Text(SoftHyphens.display("Страницата на стопанството"))
                                } else {
                                    Label("Страницата на стопанството", systemImage: "arrow.up.right.square")
                                }
                            }
                            .accessibilityLabel("Страницата на стопанството")
                            .accessibilityHint("Отваря публичната страница на стопанството.")
                            .accessibilityInputLabels(A11y.spokenNames("Страницата на стопанството", "Farm page"))
                        }
                    }
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
                    custodySection
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
        .sheet(item: $farmPage) { InAppBrowser(url: $0.url).ignoresSafeArea() }
    }

    /// «Изпълнена» and «Оттегли» on your own listing (#478), each behind its
    /// question. Gone once the listing is terminal, which is also what the
    /// server's answer to either leaves it.
    @ViewBuilder
    private var custodySection: some View {
        let actions = ListingCustodyAction.offered(status: custody.status, isOwn: listing.isOwn,
                                                   mayWrite: user.user?.mayWrite ?? false)
        if !actions.isEmpty || custody.failure != nil {
            Section {
                ForEach(actions, id: \.self) { action in
                    ListingCustodyButton(action: action, custody: custody, listingID: listing.id)
                }
                if let failure = custody.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

/// One of «Изпълнена» / «Оттегли» and its question, which iOS 26 draws as a
/// popover on the button that asked it. Not one dialog for both on the
/// section: that one pointed at «Изпълнена» while asking about «Оттегли».
private struct ListingCustodyButton: View {
    let action: ListingCustodyAction
    let custody: ListingCustody
    let listingID: String
    @State private var asking = false

    var body: some View {
        Button(role: action == .withdraw ? .destructive : nil) {
            asking = true
        } label: {
            HStack(spacing: 8) {
                Text(action.title)
                    .foregroundStyle(action == .withdraw ? Palette.destructive : Palette.accent)
                if custody.sending == action {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(custody.sending != nil)
        .accessibilityInputLabels(action.spokenNames)
        .confirmationDialog(action.confirmTitle, isPresented: $asking, titleVisibility: .visible) {
            Button(action.title, role: action == .withdraw ? .destructive : nil) {
                Task {
                    await custody.perform(action, listingID: listingID)
                    if let done = custody.done {
                        AccessibilityNotification.Announcement(done).post()
                    }
                }
            }
            .accessibilityInputLabels(action.spokenNames)
            Button("Отказ", role: .cancel) {}
                .accessibilityInputLabels(A11y.Spoken.cancel)
        } message: {
            Text(action.confirmMessage)
        }
    }
}
