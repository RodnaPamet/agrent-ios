import Foundation

/// What the map shows for one oblast.
///
/// ── EVERY AGGREGATE IS WITHIN A SINGLE CURRENCY OR IT DOES NOT EXIST ──
///
/// This is the rule the whole type is built around, and it is the one
/// thing this screen must not get wrong. Averaging 200 EUR/t with 380
/// BGN/t produces 290 of nothing — a confident number that is not a price
/// in any currency, on a screen a farmer uses to decide what to sell for.
///
/// So prices are grouped BY currency, and a region holding two currencies
/// reports two figures rather than one blended one. A lone offer in a
/// third currency keeps its own label and takes no part in any comparison.
///
/// The web does the same, and the reason is worth restating rather than
/// citing: an average is only meaningful over commensurable things, and
/// currencies are not commensurable without a rate nobody here has.
struct RegionAggregate: Equatable, Identifiable {
    let regionCode: String
    let listings: [ExchangeListing]

    var id: String { regionCode }

    /// The label, from the catalogue. NEVER `regionName` off the wire,
    /// which is English.
    var name: String {
        BulgarianRegion.name(code: regionCode, fallback: listings.first?.regionName)
            ?? regionCode
    }

    var count: Int { listings.count }

    /// Price statistics, one entry PER CURRENCY, highest count first so
    /// the dominant currency leads.
    var prices: [CurrencyPrice] {
        var byCurrency: [String: [Decimal]] = [:]
        for listing in listings {
            guard let price = listing.price,
                  let currency = listing.priceCurrency, !currency.isEmpty
            else { continue }
            byCurrency[currency, default: []].append(price)
        }
        return byCurrency
            .map { currency, values in
                CurrencyPrice(
                    currency: currency,
                    count: values.count,
                    low: values.min() ?? 0,
                    high: values.max() ?? 0,
                    average: values.reduce(0, +) / Decimal(values.count)
                )
            }
            .sorted {
                $0.count == $1.count ? $0.currency < $1.currency : $0.count > $1.count
            }
    }

    /// True when this region holds offers in more than one currency, which
    /// the screen must SAY rather than resolve. A single number would be
    /// the lie this type exists to prevent.
    var isMixedCurrency: Bool { prices.count > 1 }

    struct CurrencyPrice: Equatable {
        let currency: String
        let count: Int
        let low: Decimal
        let high: Decimal
        let average: Decimal

        /// A range only when there IS a range. "200 – 200" reads as an
        /// uncertainty that is not there.
        var isSinglePrice: Bool { low == high }
    }

    /// Group listings by region.
    ///
    /// Listings with no coordinates are DROPPED FROM THE MAP and counted
    /// separately by the caller — a marker cannot be placed for them, and
    /// silently omitting them would make the map claim a completeness it
    /// does not have.
    static func group(_ listings: [ExchangeListing]) -> [RegionAggregate] {
        var byRegion: [String: [ExchangeListing]] = [:]
        for listing in listings {
            guard let code = listing.regionCode?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  !code.isEmpty, listing.lat != nil, listing.lon != nil
            else { continue }
            byRegion[code, default: []].append(listing)
        }
        return byRegion
            .map { RegionAggregate(regionCode: $0.key, listings: $0.value) }
            .sorted { $0.count == $1.count ? $0.regionCode < $1.regionCode : $0.count > $1.count }
    }

    /// Listings the map cannot place. Surfaced, not swallowed.
    static func unplaceable(_ listings: [ExchangeListing]) -> [ExchangeListing] {
        listings.filter {
            $0.lat == nil || $0.lon == nil
                || ($0.regionCode ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
