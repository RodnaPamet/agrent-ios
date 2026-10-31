import SwiftUI

struct ExchangeView: View {
    /// Three sections. «Съобщения» was a fourth until 2026-10-24, when the
    /// owner moved it to the bar, in the place of «Ферми».
    enum Tab: String, CaseIterable, Identifiable {
        case browse, mine, inquiries
        var id: String { rawValue }
        var label: String {
            switch self {
            case .browse: "Обяви"
            case .mine: "Моите обяви"
            case .inquiries: "Моите заявки"
            }
        }
    }

    @State private var tab: Tab = .browse
    @State private var listings = ExchangeListingsStore()
    @State private var mine = MyListingsStore()
    /// Whether «Моите обяви» has been on screen, so its list reads again
    /// when it comes BACK — from a listing that «Оттегли» may have changed
    /// (#478) — and not twice on its first appearance.
    @State private var mineShown = false
    @State private var inquiries = MyInquiriesStore()
    @State private var unread = ExchangeUnreadStore.shared
    /// The farms the board's search found (owner, 2026-10-24).
    @State private var farms = BoardFarmsStore()
    @State private var farmPage: InAppPage?
    @State private var posting = false
    @State private var flags = FeatureFlags.shared

    /// Remembered per user, and the LIST is the default. The map answers
    /// "where are the offers"; the list answers "what is on offer", and
    /// the second is the question somebody opens a trading board with.
    @AppStorage("exchange.showMap") private var showMap = false

    var body: some View {
        RoutedStack {
            stack
                .navigationTitle("Борса")
                .appMenu()
                .toolbar {
                    if tab == .browse {
                        ToolbarItem(placement: .primaryAction) { filterMenu }
                        ToolbarItem(placement: .primaryAction) {
                            Button { showMap.toggle() } label: {
                                Label(showMap ? "Списък" : "Карта",
                                      systemImage: showMap ? "list.bullet" : "map")
                            }
                            .accessibilityLabel(showMap ? "Покажи списък" : "Покажи карта")
                        }
                    }
                    // PARITY GAP 3. "Моите обяви" was read-only: you could
                    // see your listings and not make one.
                    if tab == .mine {
                        ToolbarItem(placement: .primaryAction) {
                            Button { posting = true } label: {
                                Label("Нова обява", systemImage: "plus")
                            }
                        }
                    }
                    // «Съобщения» (owner, 2026-10-24), where «Ферми» was: on
                    // every section, since a conversation is about trading
                    // here rather than about one list. The farms moved into
                    // the board's search. Primary, not secondary: on a phone
                    // a secondary item folds into a «…» menu.
                    ToolbarItem(placement: .primaryAction) { messagesButton }
                }
                .sheet(isPresented: $posting) {
                    NewListingView { Task { await mine.load() } }
                }
                .sheet(item: $farmPage) { page in
                    InAppBrowser(url: page.url).ignoresSafeArea()
                }
                // The farm section asks the directory what the board just
                // asked the server: on a search, a map tap or a clear.
                .onChange(of: listings.lastAsked) { _, asked in
                    guard let asked, flags.isOn(FarmBrandAPI.flag) else { farms.clear(); return }
                    Task { await farms.load(text: asked.text, regions: asked.regions) }
                }
                .task { await loadCurrent() }
                .onChange(of: tab) { Task { await loadCurrent() } }
        }
    }

    /// The board gets a search field; the other tabs do not.
    @ViewBuilder
    private var stack: some View {
        VStack(spacing: 0) {
            ExchangeSectionPicker(selection: $tab)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if tab == .browse {
                // The app's own field, not `.searchable`: UIKit draws that
                // prompt at 3.12:1 in light and nothing styles it (#164).
                // Searched on SUBMIT, not on every keystroke — a trading
                // board is a network round trip per character otherwise, on
                // a connection this app assumes is bad, and every keystroke
                // would also be a line in the unified log.
                // Short enough for one line on a phone: the longer «Търсене по
                // култура, регион или ферма» wrapped and doubled the field's
                // height. The magnifier says it is a search.
                SearchField(text: $listings.query.text, prompt: "Култура, регион или ферма") {
                    Task { await listings.load() }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            switch tab {
            case .browse: browse
            case .mine: myListings
            case .inquiries: myInquiries
            }
        }
        // THE STRIP AROUND THE SECTION PICKER. Each list below paints the
        // page through `pageBackground()`, but the picker sits OUTSIDE them,
        // so in dark mode the band between the search field and the first
        // row was the system's black (#154 noted it). The navigation bar
        // above is the page colour too (`SolidChrome`), so the header now
        // reads as one surface from the title down.
        .background(Palette.Surface.page)
    }

    private var currentFreshness: Freshness? {
        switch tab {
        case .browse: listings.state.freshness
        case .mine: mine.state.freshness
        case .inquiries: inquiries.state.freshness
        }
    }

    private func loadCurrent() async {
        switch tab {
        case .browse: if listings.state.value == nil { await listings.load() }
        case .mine: if mine.state.value == nil { await mine.load() }
        case .inquiries: if inquiries.state.value == nil { await inquiries.load() }
        }
    }

    // MARK: - Browse: every tenant's listings, not yours

    @ViewBuilder
    private var browse: some View {
        switch listings.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            failure(message) { await listings.load() }

        // The map stays when a region filter empties the board (#417): the
        // oblast that was tapped on has to stay there to be tapped off.
        case .loaded where showMap && !listings.query.regions.isEmpty:
            mapView

        case .loaded(_, _) where listings.rows.isEmpty:
            // A filtered no-result is NOT the same statement as an empty
            // board, and saying the wrong one is a claim about the market
            // rather than about the search. "Nobody is offering anything"
            // when in fact nobody matches "пшеница over 400t" would send
            // an operator away from a board that has offers on it.
            if listings.query.isFiltered {
                EmptyState(
                    "Няма съвпадения",
                    icon: "magnifyingglass",
                    message: "Никоя обява не отговаря на търсенето."
                ) {
                    Button("Изчисти филтрите") { Task { await listings.clearFilters() } }
                }
            } else {
                EmptyState(
                    "Няма активни обяви",
                    icon: "tray",
                    message: "В момента никое стопанство не предлага нищо на борсата."
                )
            }

        case .loaded where showMap:
            mapView

        case .loaded:
            List {
                if !listings.query.regions.isEmpty {
                    Section {
                        RegionFilterSummary(regions: listings.query.regions) {
                            Task { await listings.clearRegions() }
                        }
                    }
                    .pageRow()
                }
                farmsSection
                // The table is GLOBAL — every tenant sees every active
                // listing, and that IS the product. Saying so once is cheaper
                // than a heading that quietly implies these are the user's,
                // which would be a factual lie about what is on screen.
                Section {
                    ForEach(listings.rows) { listing in
                        NavigationLink(value: AppRoute.listing(listing)) {
                            ListingRow(listing: listing)
                        }
                    }
                    loadMoreRow
                } footer: {
                    SectionFooter("Обявите са от всички стопанства в платформата.")
                }
                // On the SECTION — it propagates to the rows inside, which
                // is one modifier per section instead of one per row type.
                .pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await listings.load() } }
            .pageBackground()
        }
    }

    /// The map, filtering the board by oblast as the web's does (#417).
    private var mapView: some View {
        ExchangeMapView(
            listings: listings.rows,
            selectedRegions: listings.query.regions,
            onToggleRegion: { code in Task { await listings.toggleRegion(code) } },
            onClearRegions: { Task { await listings.clearRegions() } },
            farms: farms.hits,
            onOpenFarm: openFarm
        )
        .refreshable { await PullToRefresh.bounded { await listings.load() } }
    }

    // MARK: - Farms, from the same search (owner, 2026-10-24)

    /// The farms the search found, above the listings: someone who typed a
    /// farm's name is looking for that farm first. Nothing at all when the
    /// search found none — the board is the listings.
    @ViewBuilder
    private var farmsSection: some View {
        if !farms.hits.isEmpty {
            Section {
                ForEach(farms.hits) { hit in
                    FarmLink(hit: hit) { openFarm(hit) }
                }
            } header: {
                SectionHeader("Ферми")
            } footer: {
                SectionFooter {
                    if let footer = BoardFarmsStore.footer(count: farms.hits.count) { Text(footer) }
                }
            }
            .pageRow()
        }
    }

    private func openFarm(_ hit: FarmDirectoryHit) {
        farmPage = InAppPage.farm(handle: hit.handle)
    }

    /// «Съобщения» with the unread count on it — the count the section chip
    /// used to carry, so a waiting reply is as visible from «Моите обяви».
    private var messagesButton: some View {
        NavigationLink(value: AppRoute.exchangeInbox) {
            // The count BESIDE the icon, not a badge over its corner: the bar
            // draws its items in a capsule that clips anything outside it, so
            // an overlaid badge was not there at all.
            HStack(spacing: 3) {
                Image(systemName: "bubble.left.and.bubble.right")
                if unread.count > 0 {
                    Text(unread.count > 99 ? "99+" : "\(unread.count)")
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                }
            }
        }
        // The NAME without the count, so Voice Control's «Съобщения» keeps
        // matching as the count changes; the count is the value.
        .accessibilityLabel("Съобщения")
        .accessibilityValue(unread.count > 0
            ? Plural.bg(unread.count, "непрочетен разговор", "непрочетени разговора")
            : "")
        .accessibilityInputLabels(A11y.Spoken.messages)
    }

    /// PARITY GAP 2. The board sent no query string at all, so it showed an
    /// unfiltered first page with no way to search and no way to reach page
    /// two. On a board that grows, "no way to reach page two" degrades
    /// SILENTLY — the screen keeps looking correct while holding less and
    /// less of the truth.
    @ViewBuilder
    private var loadMoreRow: some View {
        if listings.hasMore {
            VStack(alignment: .leading, spacing: 6) {
                if listings.loadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Зареждане…").font(.footnote).foregroundStyle(Palette.secondaryText)
                    }
                } else {
                    Button("Покажи още") { Task { await listings.loadMore() } }
                }
                if let error = listings.loadMoreError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Min/max tonnage, as a menu rather than a filter screen.
    ///
    /// Ranges rather than free numeric entry: a trading board is scanned
    /// by rough size — "small lots", "a truckload", "a train" — and two
    /// numeric keyboards on a phone to express that is more precision than
    /// the question has.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Picker("Количество", selection: Binding(
                get: { TonnageBand.matching(listings.query) },
                set: { band in
                    listings.query.minTonnes = band.min
                    listings.query.maxTonnes = band.max
                    Task { await listings.load() }
                }
            )) {
                ForEach(TonnageBand.allCases) { Text($0.label).tag($0) }
            }
            // Explicit, as every `Picker` in the app is (`ListChromeTests`):
            // inside a `Menu` the options are the menu's own rows.
            .pickerStyle(.inline)
            if listings.query.isFiltered {
                Divider()
                Button("Изчисти филтрите") { Task { await listings.clearFilters() } }
            }
        } label: {
            Label(
                "Филтри",
                systemImage: listings.query.isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        // THE NAME IS STABLE, THE STATE IS A VALUE.
        //
        // This read «Филтри, активни» once a filter was on — so a Voice
        // Control user said «Филтри», opened the menu, picked a tonnage band,
        // and the control they had just used stopped answering to the name
        // they had just used. A name that changes as a side effect of using it
        // is the one thing a spoken interface cannot tolerate.
        .accessibilityLabel("Филтри")
        .accessibilityValue(listings.query.isFiltered ? "активни" : "")
        .accessibilityInputLabels(A11y.Spoken.filters)
    }

    // MARK: - Mine: the seller's custody view

    @ViewBuilder
    private var myListings: some View {
        switch mine.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            failure(message) { await mine.load() }

        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Нямате обяви",
                icon: "tray",
                message: "Тук се появяват обявите, които вашето стопанство е публикувало."
            )

        case .loaded(let rows, _):
            List(rows) { row in
                // The listing's own screen, as a board row opens it (owner,
                // 2026-10-31, #478): there are «Изпълнена» and «Оттегли».
                NavigationLink(value: AppRoute.listing(ExchangeListing(own: row))) {
                    MyListingRow(listing: row)
                }
                // The row's own background, which `pageBackground()` does
                // not reach: without it each listing sat on the system's
                // grouped card colour on the page — found by the per-list
                // check in `FormSurfaceTests` (#164).
                .pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await mine.load() } }
            .pageBackground()
            .onAppear {
                if mineShown { Task { await mine.load() } }
                mineShown = true
            }
        }
    }

    // MARK: - Inquiries this tenant sent

    @ViewBuilder
    private var myInquiries: some View {
        switch inquiries.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            failure(message) { await inquiries.load() }

        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Нямате заявки",
                icon: "paperplane",
                message: "Тук се появяват запитванията, които сте изпратили към чужди обяви."
            )

        case .loaded(let rows, _):
            // `pageRow()` for the reason «Моите обяви» has one.
            List(rows) { InquiryRow(inquiry: $0).pageRow() }
                .refreshable { await PullToRefresh.bounded { await inquiries.load() } }
            .pageBackground()
        }
    }

    @ViewBuilder
    private func failure(_ message: String, retry: @escaping () async -> Void) -> some View {
        ErrorState(message: message, retry: retry)
    }
}

// MARK: - Shared pieces

/// Борса's four sections.
///
/// ── Four do not fit a phone's segmented control, MEASURED ──
///
/// `UISegmentedControl` gives every segment the width of the widest, and
/// «Съобщения (3)» and «Моите заявки» are each about 95pt at the control's
/// 13pt: the four ask for 464pt (read off the control's own
/// `intrinsicContentSize` in the simulator, 2026-09-30), and an iPhone 17
/// leaves 370 inside the page margins. A segmented control that runs out of
/// room TRUNCATES, and «Моите о…» beside «Моите з…» is one word twice. The
/// three segments this replaces needed about 330 and fitted.
///
/// So the house precedent: `ParcelMapView`'s scrolling row of chips, which
/// keeps every section on screen — a menu (`TrendsView`'s answer to nine)
/// would hide the one section with news behind a tap, and the count in its
/// label is how a farmer finds it. Segments survive where they fit — an iPad,
/// a wide window — through `ViewThatFits`.
///
/// At the ACCESSIBILITY sizes the chips are unconditional, not measured — the
/// reasoning `AdaptiveRow` records: decided from the size, a later change to
/// a label cannot quietly flip it back.
///
/// Not seen on a device; see ROADMAP.md's known-unverified list.
struct ExchangeSectionPicker: View {
    @Binding var selection: ExchangeView.Tab

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if typeSize.isAccessibilitySize {
            chips
        } else {
            ViewThatFits(in: .horizontal) {
                Picker("Изглед", selection: $selection) {
                    ForEach(ExchangeView.Tab.allCases) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                chips
            }
        }
    }

    /// ── The selected chip is always the one you can read (agrent-ios#124) ──
    ///
    /// A row that scrolls hides whatever is past its edge, and on a 402pt
    /// phone that was «Съобщения» — the LAST chip, so the section the farmer
    /// had just chosen sat clipped at «Съобщ…». So the row brings the
    /// selection into view itself, at three moments:
    ///
    ///   - on appear: the picker is REBUILT whenever Борса leaves or enters
    ///     the searchable «Обяви» branch, and a fresh row starts at its left
    ///     edge whatever is selected;
    ///   - on a selection change: a tap on a half-visible chip, or Voice
    ///     Control's «Съобщения», which selects without scrolling anything;
    ///   - on an unread change: «Съобщения» grows to «Съобщения (3)» when the
    ///     count lands — AFTER the row appeared — and pushes its own end out.
    ///
    /// `anchor: nil`: `ScrollViewReader` then scrolls the LEAST that makes
    /// the chip fully visible, so choosing a chip already on screen does not
    /// jolt the row. (`scrollPosition(id:)` is iOS 17 too, but it aligns to
    /// an edge; nothing here is from iOS 18 — the target is 17.)
    ///
    /// Reduce Motion: the conversation's rule — with it on, the row jumps.
    /// The appear and the count are never animated: those are where the row
    /// STARTS, not a movement the farmer caused.
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ExchangeView.Tab.allCases) { tab in
                        chip(tab).id(tab)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { reveal(selection, proxy, animated: false) }
            .onChange(of: selection) { _, new in reveal(new, proxy, animated: true) }
        }
        .scrollIndicators(.hidden)
        // One container of buttons for VoiceOver, named as the picker was.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Изглед")
    }

    private func reveal(_ tab: ExchangeView.Tab, _ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(tab, anchor: nil) }
        } else {
            proxy.scrollTo(tab, anchor: nil)
        }
    }

    private func chip(_ tab: ExchangeView.Tab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            // The fill is the only mark of the selected chip, so with
            // Differentiate Without Colour it carries a tick as well.
            HStack(spacing: 4) {
                if isSelected && withoutColor {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
                Text(label(for: tab))
            }
            .font(.footnote.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // The parcel map's chip, pair for pair: `onAccent` on `accent`,
            // measured in `Palette`.
            .background(isSelected ? Palette.accent : Palette.Chip.neutralFill, in: Capsule())
            .foregroundStyle(isSelected ? Palette.onAccent : Color.primary)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.label)
    }

    /// The unread count moved to «Съобщения» on the bar (2026-10-24).
    private func label(for tab: ExchangeView.Tab) -> String { tab.label }
}

struct ListingRow: View {
    let listing: ExchangeListing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `AdaptiveRow`, as the inbox's row has. A plain `HStack` gave the
            // chip its width first and broke the crop to fit beside it: «Пшен
            // / ица» at AX5 (A11yShots, 2026-10-08).
            AdaptiveRow {
                Text(CommodityName.canonical(listing.commodity) ?? listing.commodity).font(.headline)
                // The only thing distinguishing your rows in a global table.
                if listing.isOwn {
                    CategoryChip(
                        text: "ваша",
                        foreground: Palette.Chip.neutralText,
                        background: Palette.Chip.neutralFill
                    )
                }
            }
            ListingSummary(side: listing.side, kind: listing.kind,
                           quantity: listing.quantityTonnes, price: listing.pricePerTonne,
                           currency: listing.priceCurrency)
            if let region = listing.region {
                Text(region).font(.footnote).foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 2)
        // Борса's rows are the only tappable thing on the board, and a
        // Voice Control user could not name one: the spoken label is the whole
        // sentence, so saying the crop matched nothing. The crop is what is
        // printed largest and what a person would actually say.
        .accessibleRow(
            spoken: Self.spoken(listing),
            // The server's slug is the English word, so the English name
            // costs nothing to offer — see `A11y.spokenNames`.
            saying: A11y.spokenNames(
                CommodityName.canonical(listing.commodity), listing.commodity))
    }

    /// ONE stop, spoken from the values: everything the row prints, in the
    /// order it prints it, as the inbox's row is.
    ///
    /// It said the crop, the side and the region, so «ваша», the quantity
    /// and the price were on the screen and nowhere in the audio — the one
    /// marker of your own listing, and the two figures a trader reads
    /// first. «ваша» comes second, where it is printed, for the reason
    /// «ново» comes early in the inbox: someone scanning the board hears it
    /// before the details.
    ///
    /// Figures as words, through `Exchange.spokenTonnes` and `spokenPrice`:
    /// «250 тона», «51,13 евро на тон».
    ///
    /// `nonisolated`: a `View`'s members are the main actor's, and this is a
    /// pure function of a `Sendable` value that the tests call directly.
    nonisolated static func spoken(_ listing: ExchangeListing) -> String {
        A11y.sentence([
            CommodityName.canonical(listing.commodity) ?? listing.commodity,
            listing.isOwn ? "ваша" : nil,
            listing.side.label,
            listing.kind.label,
            Exchange.spokenTonnes(listing.quantityTonnes),
            Exchange.spokenPrice(listing.pricePerTonne, currency: listing.priceCurrency),
            listing.region,
        ])
    }
}

/// A row of «Моите обяви»: the seller's own listing, and the inquiries on it.
struct MyListingRow: View {
    let listing: OwnExchangeListing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                // `AdaptiveRow` for the reason `ListingRow` has one.
                AdaptiveRow {
                    Text(CommodityName.canonical(listing.commodity) ?? listing.commodity)
                        .font(.headline)
                        // The status on the trailing edge while the two
                        // share a line, as the `Spacer` this replaced put it
                        // — and no empty gap under the crop once they stack,
                        // which a `Spacer` in a stack would leave.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(listing.status.label)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
                ListingSummary(side: listing.side, kind: listing.kind,
                               quantity: listing.quantityTonnes, price: listing.pricePerTonne,
                               currency: listing.priceCurrency)
            }
            // ONE stop for the listing, spoken from the values (#220). It was
            // three — the crop, the status, and the summary read as printed,
            // «·» and «/ т» included. The inquiries under it stay stops of
            // their own: each is a different person's message.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(listing))

            if listing.inquiries.isEmpty {
                Text("Няма запитвания").font(.footnote).foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(listing.inquiries) { inquiry in
                    InquiryRow(inquiry: inquiry)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The board row's wording, in this row's order: the crop, its status,
    /// then the summary's values. No «ваша» — every row here is.
    nonisolated static func spoken(_ listing: OwnExchangeListing) -> String {
        A11y.sentence([
            CommodityName.canonical(listing.commodity) ?? listing.commodity,
            listing.status.label,
            listing.side.label,
            listing.kind.label,
            Exchange.spokenTonnes(listing.quantityTonnes),
            Exchange.spokenPrice(listing.pricePerTonne, currency: listing.priceCurrency),
        ])
    }
}

struct InquiryRow: View {
    let inquiry: ExchangeInquiry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(inquiry.status.label).font(.subheadline.weight(.medium))
                Spacer()
                Text(BgDate.full(inquiry.createdAt))
                    .font(.footnote).foregroundStyle(Palette.secondaryText)
            }
            if !inquiry.message.isEmpty {
                Text(inquiry.message).font(.footnote).foregroundStyle(Palette.secondaryText).lineLimit(3)
            }
            // CONTACT DETAILS ARE WITHHELD UNTIL contactSharedAt IS SET, and
            // that withholding is the feature. A PENDING or DECLINED inquiry
            // legitimately shows no contact for EITHER party, so there is no
            // empty "Контакт" row and no "не е налично" — both read as missing
            // data and invite someone to treat the privacy rule as a bug.
            // Only the positive case is rendered.
            if inquiry.contactShared {
                Label("Контактите са споделени", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 2)
        // One stop per inquiry (#220), where VoiceOver stepped through its
        // status, date, message and note one by one. `.combine` rather than
        // a built label: every child is plain words — no `·`, no symbol —
        // so what it reads is what a built label would say. It also reads
        // the WHOLE message, which `lineLimit(3)` cuts on screen.
        .accessibilityElement(children: .combine)
    }
}

/// "Продава · Култура · 250 т · 51,13 EUR / т"
///
/// ── The old comment was half right, and the half that was wrong shipped ──
///
/// It said the strings are "printed as sent" because "parsing them into a
/// Double to reformat would put binary rounding into a price on a
/// marketplace". The premise is correct — `Double` would — and the
/// conclusion does not follow: `Decimal` is base-10 and exact at these
/// magnitudes, so the value can be reformatted without rounding anything.
///
/// Printing as sent put `51.13 EUR` on a Bulgarian screen, where the
/// separator is a comma. A price with the wrong decimal mark on a trading
/// board is not a typographic nicety; it is the one figure a farmer
/// reconciles against an invoice.
///
/// Scales differ because the quantities differ in kind. A price is money
/// and takes its currency's two places, so `51.13` reads `51,13`. A tonnage
/// is a measurement and keeps up to three without padding, so `250` stays
/// `250` rather than becoming `250,000`.
///
/// ── Where a line may end ──
///
/// Never between a number and its unit. With plain spaces, AX5 drew «250 /
/// т» and a line reading «т · 51,13 EUR /» (A11yShots, 2026-10-08), so the
/// spaces inside «250 т», «51,13 EUR» and «/ т» are no-break. The one
/// before the slash stays breakable: a 4-digit price with its currency and
/// «/ т» all bound would be wider than an SE's line at AX5, and a run that
/// cannot fit is cut wherever it runs out — «EU / R». The dot is bound to
/// the value before it, so a wrapped line ends on one and never starts
/// with one.
///
/// `stacked`, at the accessibility sizes: a value per line and no dots,
/// as `MetaRow` and `MetaSeparator` do. Still one `Text` rather than a
/// `MetaRow` because of the sizes below those: four values overrun a line
/// from xLarge up, and a `MetaRow`'s `HStack` would squeeze them into
/// columns where one `Text` wraps.
func summary(side: ExchangeSide, kind: ExchangeKind,
             quantity: String?, price: String?, currency: String?,
             stacked: Bool) -> String {
    let bound = "\u{00A0}"
    var parts = [side.label, kind.label]
    if let tonnes = Exchange.tonnes(quantity) { parts.append("\(tonnes)\(bound)т") }
    if let money = Exchange.money(price) {
        let amount = [money, currency ?? ""].filter { !$0.isEmpty }.joined(separator: bound)
        parts.append("\(amount) /\(bound)т")
    }
    return parts.joined(separator: stacked ? "\n" : "\(bound)· ")
}

/// `summary` as a row draws it, deciding `stacked` from the text size the
/// way `MetaRow` does — so the board's rows and «Моите обяви» cannot
/// disagree about it.
struct ListingSummary: View {
    let side: ExchangeSide
    let kind: ExchangeKind
    let quantity: String?
    let price: String?
    let currency: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(summary(side: side, kind: kind, quantity: quantity, price: price,
                     currency: currency, stacked: typeSize.isAccessibilitySize))
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
    }
}

/// Formatting for the exchange's wire decimals, which are STRINGS here —
/// these routes have no DTO, unlike `grain/costs`. See `WireDecimal`.
enum Exchange {
    /// Money: exactly two places, the currency's scale. `51.13` → `51,13`.
    static func money(_ raw: String?) -> String? {
        guard let value = WireDecimal.parse(raw) else { return raw }
        return value.formatted(
            .number.precision(.fractionLength(2)).grouping(.automatic)
                .locale(BgDate.locale))
    }

    /// A measurement: up to three places, not padded. `250` → `250`.
    static func tonnes(_ raw: String?) -> String? {
        guard let value = WireDecimal.parse(raw) else { return raw }
        return value.formatted(
            .number.precision(.fractionLength(0...3)).grouping(.automatic)
                .locale(BgDate.locale))
    }

    /// A tonnage as a voice says it: «250 тона», «1 тон». Exactly one is
    /// the only singular — «21 тона», «0,5 тона» — as the inbox counted.
    static func spokenTonnes(_ raw: String?) -> String? {
        tonnes(raw).map { "\($0) \(WireDecimal.parse(raw) == 1 ? "тон" : "тона")" }
    }

    /// A price per tonne as a voice says it: «51,13 евро на тон». The
    /// printed «EUR / т» is read out as three letters and a slash.
    static func spokenPrice(_ raw: String?, currency: String?) -> String? {
        money(raw).map { money in
            let unit = currency.flatMap { $0.isEmpty ? nil : CurrencyWords.name($0, afterNumber: true) }
            return [money, unit, "на тон"].compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// The tonnage bands the board is filtered by.
///
/// Named ranges rather than two numeric fields: a trading board is scanned
/// by rough size, and asking for exact tonnes is more precision than the
/// question carries. The server takes `minTonnes`/`maxTonnes`, so these
/// are a UI over the same two parameters rather than a different contract.
enum TonnageBand: String, CaseIterable, Identifiable {
    case any, small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Всяко количество"
        case .small: "До 50 т"
        case .medium: "50 – 500 т"
        case .large: "Над 500 т"
        }
    }

    var min: Int? {
        switch self {
        case .any, .small: nil
        case .medium: 50
        case .large: 500
        }
    }

    var max: Int? {
        switch self {
        case .any, .large: nil
        case .small: 50
        case .medium: 500
        }
    }

    /// Which band a query currently expresses. Falls back to `.any` for a
    /// combination no band produces — a query built by an older build, or
    /// by hand — rather than silently rewriting it.
    static func matching(_ query: ExchangeQuery) -> TonnageBand {
        allCases.first { $0.min == query.minTonnes && $0.max == query.maxTonnes } ?? .any
    }
}
