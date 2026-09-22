import Foundation
import Observation
import SwiftUI

/// One chart's worth of series: everything sharing a unit AND a currency.
///
/// The grouping IS the safety rule. Wheat comes back as
/// `dollar per metric ton` in USD from Alpha Vantage and `EUR/t` in EUR
/// from the EC feed; plotting those on one axis would draw a price jump
/// that is an exchange rate. Same rule the exchange map already enforces —
/// every aggregate is within a single currency or does not exist.
struct SeriesGroup: Identifiable {
    let unit: String
    let currency: String
    let series: [PriceSeries]

    var id: String { "\(unit)|\(currency)" }
}

@Observable
@MainActor
final class TrendsStore {
    private(set) var prices: LoadState<PricesResponse> = .loading
    private(set) var news: LoadState<NewsResponse> = .loading

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
    var newsCategory: NewsCategory = .all

    /// Which series are drawn. Reset and re-derived whenever the commodity
    /// changes, since an id from the previous commodity means nothing here.
    var hiddenSeriesIDs: Set<String> = []

    /// Set the moment the farmer touches the legend.
    ///
    /// Without it, `applyDefaultVisibility` runs on every load and switching
    /// 1 год. → 3 мес. silently undoes their choice of lines. The comment on
    /// `select(_ range:)` claimed the choice survived; it did not, until
    /// this existed.
    private var seriesChosenByHand = false

    func loadPrices() async {
        if prices.value == nil { prices = .loading }
        let path = TrendsAPI.pricesPath(commodity, range: range)
        prices = await CachedResource.load(path) { data in
            try await APIClient.shared.decode(data, as: PricesResponse.self)
        }
        applyDefaultVisibility()
    }

    /// Start with Bulgaria, not with everything.
    ///
    /// Wheat's EUR/t group is the EC agri-food feed, which quotes every
    /// member state — the first build drew all of them and produced
    /// fifteen overlapping lines in one 220-point-tall chart, from which
    /// nothing at all could be read. Showing more data than can be
    /// distinguished is not more information.
    ///
    /// So the default is the series this farm is in: region BG, plus any
    /// GLOBAL reference, which is the benchmark a Bulgarian price is
    /// judged against. Everything else stays one tap away in the legend
    /// rather than being removed.
    ///
    /// If a group has neither — a commodity quoted only elsewhere — the
    /// first series is shown, because an empty chart under a full legend
    /// reads as a load failure.
    func loadNews() async {
        if news.value == nil { news = .loading }
        let path = TrendsAPI.newsPath(newsCategory)
        news = await CachedResource.load(path) { data in
            try await APIClient.shared.decode(data, as: NewsResponse.self)
        }
    }

    func select(_ commodity: ChartableCommodity) async {
        guard commodity != self.commodity else { return }
        self.commodity = commodity
        // A series id from the previous commodity means nothing here, and
        // left in place it would hide a line the farmer never hid.
        hiddenSeriesIDs = []
        seriesChosenByHand = false
        prices = .loading
        await loadPrices()
    }

    func select(_ range: PriceRange) async {
        guard range != self.range else { return }
        self.range = range
        // Series ids are stable across ranges — same feeds, fewer points —
        // so a hidden line stays hidden, which is what a reader comparing
        // 3m against 1y expects. `loadPrices` re-derives defaults only for
        // series it has not seen.
        await loadPrices()
    }

    func select(_ category: NewsCategory) async {
        guard category != newsCategory else { return }
        newsCategory = category
        news = .loading
        await loadNews()
    }

    private func applyDefaultVisibility() {
        guard !seriesChosenByHand else { return }
        var hidden: Set<String> = []
        for group in groups {
            let preferred = group.series.filter {
                ["BG", "GLOBAL"].contains($0.region.uppercased())
            }
            let candidates = preferred.isEmpty ? group.series : preferred
            // Freshest first, then the longest history — a series observed
            // last week says more about today than one that stopped in
            // spring, and between two equally current ones the longer
            // record is the better line.
            let ranked = candidates.sorted { left, right in
                let l = left.lastObservedAt ?? ""
                let r = right.lastObservedAt ?? ""
                if l != r { return l > r }
                return left.points.count > right.points.count
            }
            let shownIDs = Set(ranked.prefix(Self.defaultSeriesCap).map(\.id))
            for series in group.series where !shownIDs.contains(series.id) {
                hidden.insert(series.id)
            }
        }
        hiddenSeriesIDs = hidden
    }

    /// Three.
    ///
    /// Filtering to Bulgaria was not enough on its own: the EC agri-food
    /// feed quotes nine separate Bulgarian delivery points for wheat, so
    /// "region BG" still produced nine overlapping lines in a 220-point
    /// chart. Twenty-three lines and nine lines are both unreadable, and
    /// the difference between them is not worth having.
    ///
    /// Three is the most that can be told apart at this height across a
    /// year of weekly observations. The rest are one tap away in the
    /// legend, which lists every series with its own latest price and age
    /// whether it is drawn or not — so nothing is hidden from the reader,
    /// only from the chart.
    static let defaultSeriesCap = 3

    #if DEBUG
    /// Lets a test put a captured production payload into the store without
    /// a network round trip. The grouping rules are the thing under test and
    /// they are worth exercising against real series rather than a fixture
    /// written to agree with them.
    func resetSeriesChoiceForTesting() {
        seriesChosenByHand = false
        hiddenSeriesIDs = []
    }

    func setPricesForTesting(_ response: PricesResponse, applyDefaults: Bool = false) {
        prices = .loaded(response, .fresh)
        if applyDefaults { applyDefaultVisibility() }
    }
    #endif

    /// One group per (unit, currency), each a separate chart.
    var groups: [SeriesGroup] {
        guard let response = prices.value else { return [] }
        var order: [String] = []
        var buckets: [String: [PriceSeries]] = [:]
        for series in response.series where !series.points.isEmpty {
            let key = "\(series.unit)|\(series.currency)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(series)
        }
        return order.compactMap { key in
            guard let series = buckets[key], let first = series.first else { return nil }
            return SeriesGroup(unit: first.unit, currency: first.currency, series: series)
        }
    }

    func isVisible(_ series: PriceSeries) -> Bool { !hiddenSeriesIDs.contains(series.id) }

    func toggle(_ series: PriceSeries) {
        seriesChosenByHand = true
        if hiddenSeriesIDs.contains(series.id) {
            hiddenSeriesIDs.remove(series.id)
        } else {
            // Never hide the last visible line in a group — an empty chart
            // with a full legend reads as a load failure.
            let group = groups.first { $0.series.contains { $0.id == series.id } }
            let visible = group?.series.filter(isVisible) ?? []
            guard visible.count > 1 else { return }
            hiddenSeriesIDs.insert(series.id)
        }
    }

    /// Days between a series' last observation and the payload's own
    /// build time — both server values. See `Staleness`.
    func staleDays(_ series: PriceSeries) -> Int? {
        guard let generatedAt = prices.value?.generatedAt else { return nil }
        return Staleness.days(generatedAt: generatedAt, lastObservedAt: series.lastObservedAt)
    }

    /// The colour a series is drawn in, and the SAME colour its legend dot
    /// gets — they were different, and a legend whose swatches do not match
    /// the lines is worse than no legend, because it looks authoritative.
    ///
    /// Assigned by position within the group so the mapping is stable for a
    /// given payload, and handed to the chart explicitly via
    /// `chartForegroundStyleScale` rather than left to the automatic scale,
    /// which is what allowed the two to disagree.
    func colour(for series: PriceSeries, in group: SeriesGroup) -> Color {
        let index = group.series.firstIndex { $0.id == series.id } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    /// Distinguishable at a glance and distinguishable to the common forms
    /// of colour blindness — a chart's colours are its only key.
    static let palette: [Color] = [
        Color(red: 0.00, green: 0.45, blue: 0.70),
        Color(red: 0.84, green: 0.37, blue: 0.00),
        Color(red: 0.00, green: 0.62, blue: 0.45),
        Color(red: 0.80, green: 0.47, blue: 0.65),
        Color(red: 0.34, green: 0.71, blue: 0.91),
        Color(red: 0.94, green: 0.89, blue: 0.26),
        Color(red: 0.35, green: 0.35, blue: 0.35),
    ]

    /// The most recent price in a series, with its day.
    func latest(_ series: PriceSeries) -> PricePoint? {
        series.points.max { ($0.day ?? .distantPast) < ($1.day ?? .distantPast) }
    }
}
