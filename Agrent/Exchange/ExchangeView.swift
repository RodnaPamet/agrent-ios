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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            .navigationTitle("Борса")
            .task { await loadCurrent() }
            .onChange(of: tab) { Task { await loadCurrent() } }
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

        case .loaded(let page, _) where page.rows.isEmpty:
            EmptyState(
                "Няма активни обяви",
                icon: "tray",
                message: "В момента никое стопанство не предлага нищо на борсата."
            )

        case .loaded(let page, _):
            List {
                // The table is GLOBAL — every tenant sees every active
                // listing, and that IS the product. Saying so once is cheaper
                // than a heading that quietly implies these are the user's,
                // which would be a factual lie about what is on screen.
                Section {
                    ForEach(page.rows) { listing in
                        NavigationLink {
                            ListingDetailView(listing: listing)
                        } label: {
                            ListingRow(listing: listing)
                        }
                    }
                } footer: {
                    Text("Обявите са от всички стопанства в платформата.")
                }
            }
            .refreshable { await listings.load() }
        }
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
                        Text(row.commodity).font(.headline)
                        Spacer()
                        Text(row.status.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(summary(side: row.side, kind: row.kind,
                                 quantity: row.quantityTonnes, price: row.pricePerTonne,
                                 currency: row.priceCurrency))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if row.inquiries.isEmpty {
                        Text("Няма запитвания").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(row.inquiries) { inquiry in
                            InquiryRow(inquiry: inquiry)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .refreshable { await mine.load() }
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
                .refreshable { await inquiries.load() }
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
                Text(listing.commodity).font(.headline)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let region = listing.regionName {
                Text(region).font(.subheadline).foregroundStyle(.secondary)
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
                    Text(created, format: .dateTime.day().month().year())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let message = inquiry.message, !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            // CONTACT DETAILS ARE WITHHELD UNTIL contactSharedAt IS SET, and
            // that withholding is the feature. A PENDING or DECLINED inquiry
            // legitimately shows no contact for EITHER party, so there is no
            // empty "Контакт" row and no "не е налично" — both read as missing
            // data and invite someone to treat the privacy rule as a bug.
            // Only the positive case is rendered.
            if inquiry.contactShared {
                Label("Контактите са споделени", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Продава · Култура · 250 т · 51.13 EUR/т"
///
/// Quantity and price are the payload's STRINGS, printed as sent. They are
/// Prisma decimals serialised as text; parsing them into a Double to reformat
/// would put binary rounding into a price on a marketplace.
func summary(side: ExchangeSide, kind: ExchangeKind,
             quantity: String?, price: String?, currency: String?) -> String {
    var parts = [side.label, kind.label]
    if let quantity { parts.append("\(quantity) т") }
    if let price { parts.append("\(price) \(currency ?? "") / т".trimmingCharacters(in: .whitespaces)) }
    return parts.joined(separator: " · ")
}
