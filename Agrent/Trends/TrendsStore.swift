import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class TrendsStore {
    private(set) var prices: LoadState<PricesResponse> = .loading

    /// A `ChartableCommodity`, never a raw slug string.
    ///
    /// The CI guard flags any file touching `.commodity` that does not
    /// name `CommodityName`, because the failure it exists to catch is a
    /// new screen writing `Text(row.commodity)` and shipping the server's
    /// English. That cannot happen here — this is an enum, and its only
    /// rendering is `ChartableCommodity.label`, which resolves through
    /// `CommodityName.canonical`. Recorded rather than worked around: the
    /// guard is right to make someone say why.
    var commodity: ChartableCommodity = .wheat
    var range: PriceRange = .default

    func loadPrices() async {
        if prices.value == nil { prices = .loading }
        let path = TrendsAPI.pricesPath(commodity, range: range)
        await CachedResource.loadShowingCacheFirst(path) { data in
            try await APIClient.shared.decode(data, as: PricesResponse.self)
        } publish: { [weak self] in self?.prices = $0 }
    }

    func select(_ commodity: ChartableCommodity) async {
        guard commodity != self.commodity else { return }
        self.commodity = commodity
        prices = .loading
        await loadPrices()
    }

    func select(_ range: PriceRange) async {
        guard range != self.range else { return }
        self.range = range
        await loadPrices()
    }

    #if DEBUG
    /// Lets a test put a captured production payload into the store without
    /// a network round trip. The selection rule is the thing under test and
    /// it is worth exercising against real series rather than a fixture
    /// written to agree with it.
    func setPricesForTesting(_ response: PricesResponse) {
        prices = .loaded(response, .fresh)
    }
    #endif

    /// THE series: its price above the chart, its line, its one info row
    /// (#409). The rest of the payload is not on this screen — the owner's
    /// choice, as on the web: the delivery points disagree by tens of euros
    /// and the national average answers "what is it worth".
    var lead: PriceSeries? { prices.value?.lead }

    /// The lead's points in date order, the ones the chart draws.
    var leadPoints: [(day: Date, price: Double)] {
        (lead?.points ?? []).compactMap { point in point.day.map { (day: $0, price: point.price) } }
            .sorted { $0.day < $1.day }
    }

    /// How the lead moved across the range on screen, or nil with fewer than
    /// two points.
    var change: PeriodChange? { lead.flatMap(PeriodChange.init) }

    /// Days between the lead's last observation and the payload's own build
    /// time — both server values. See `Staleness`.
    var staleDays: Int? { prices.value?.leadStaleDays }

    /// The most recent price in the lead, with its day.
    var latest: PricePoint? {
        lead?.points.max { ($0.day ?? .distantPast) < ($1.day ?? .distantPast) }
    }
}
