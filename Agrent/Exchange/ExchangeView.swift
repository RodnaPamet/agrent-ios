import SwiftUI

struct ExchangeView: View {
    private enum Tab: String, CaseIterable, Identifiable {
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
    @State private var inquiries = MyInquiriesStore()
    @State private var posting = false

    /// Remembered per user, and the LIST is the default. The map answers
    /// "where are the offers"; the list answers "what is on offer", and
    /// the second is the question somebody opens a trading board with.
    @AppStorage("exchange.showMap") private var showMap = false

    var body: some View {
        NavigationStack {
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
                }
                .sheet(isPresented: $posting) {
                    NewListingView { Task { await mine.load() } }
                }
                // On SUBMIT, not on every keystroke. A trading board is a
                // network round trip per character otherwise, on a
                // connection this app assumes is bad — and every one of
                // those keystrokes is also a line in the unified log.
                .onSubmit(of: .search) { Task { await listings.load() } }
                .task { await loadCurrent() }
                .onChange(of: tab) { Task { await loadCurrent() } }
        }
    }

    /// Conditionally searchable, so the board gets a search field and the
    /// other two tabs keep a plain navigation bar.
    @ViewBuilder
    private var stack: some View {
        let content = VStack(spacing: 0) {
            Picker("Изглед", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let age = currentFreshness?.ageDescription {
                StaleBanner(age: age)
            }

            switch tab {
            case .browse: browse
            case .mine: myListings
            case .inquiries: myInquiries
            }
        }

        if tab == .browse {
            content.searchable(
                text: $listings.query.text,
                prompt: "Търсене по култура или регион"
            )
        } else {
            content
        }
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
            ExchangeMapView(listings: listings.rows)
                .refreshable { await PullToRefresh.bounded { await listings.load() } }

        case .loaded:
            List {
                // The table is GLOBAL — every tenant sees every active
                // listing, and that IS the product. Saying so once is cheaper
                // than a heading that quietly implies these are the user's,
                // which would be a factual lie about what is on screen.
                Section {
                    ForEach(listings.rows) { listing in
                        NavigationLink {
                            ListingDetailView(listing: listing)
                        } label: {
                            ListingRow(listing: listing)
                        }
                    }
                    loadMoreRow
                } footer: {
                    Text("Обявите са от всички стопанства в платформата.")
                }
            }
            .refreshable { await PullToRefresh.bounded { await listings.load() } }
        }
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
                        Text("Зареждане…").font(.footnote).foregroundStyle(.secondary)
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
        .accessibilityLabel(listings.query.isFiltered ? "Филтри, активни" : "Филтри")
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(CommodityName.canonical(row.commodity) ?? row.commodity).font(.headline)
                        Spacer()
                        Text(row.status.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(summary(side: row.side, kind: row.kind,
                                 quantity: row.quantityTonnes, price: row.pricePerTonne,
                                 currency: row.priceCurrency))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if row.inquiries.isEmpty {
                        Text("Няма запитвания").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(row.inquiries) { inquiry in
                            InquiryRow(inquiry: inquiry)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .refreshable { await PullToRefresh.bounded { await mine.load() } }
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
            List(rows) { InquiryRow(inquiry: $0) }
                .refreshable { await PullToRefresh.bounded { await inquiries.load() } }
        }
    }

    @ViewBuilder
    private func failure(_ message: String, retry: @escaping () async -> Void) -> some View {
        ErrorState(message: message, retry: retry)
    }
}

// MARK: - Shared pieces

struct ListingRow: View {
    let listing: ExchangeListing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
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
            Text(summary(side: listing.side, kind: listing.kind,
                         quantity: listing.quantityTonnes, price: listing.pricePerTonne,
                         currency: listing.priceCurrency))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let region = listing.regionName {
                Text(region).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct InquiryRow: View {
    let inquiry: ExchangeInquiry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(inquiry.status?.label ?? "—").font(.subheadline.weight(.medium))
                Spacer()
                if let created = inquiry.createdAt {
                    Text(BgDate.full(created))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let message = inquiry.message, !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
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
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Продава · Култура · 250 т · 51,13 EUR/т"
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
func summary(side: ExchangeSide, kind: ExchangeKind,
             quantity: String?, price: String?, currency: String?) -> String {
    var parts = [side.label, kind.label]
    if let tonnes = Exchange.tonnes(quantity) { parts.append("\(tonnes) т") }
    if let money = Exchange.money(price) {
        parts.append("\(money) \(currency ?? "") / т".trimmingCharacters(in: .whitespaces))
    }
    return parts.joined(separator: " · ")
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
