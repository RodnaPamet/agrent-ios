import Foundation
import Observation

/// «Табло», which is FOUR INDEPENDENT READS rather than one screen's worth.
///
/// ── Four states, not one ──
///
/// The server has no combined route: the ag payload, the two trend endpoints
/// and the briefing are four requests, the briefing is under a different
/// prefix, and the price series come from `/trends/prices`. Held in one
/// `LoadState` they would fail together, so a briefing the model could not
/// produce would blank the journal beside it. Each block therefore owns its
/// own state and its own failure.
///
/// ── Only what is on screen is fetched ──
///
/// The farmer chooses which blocks appear, so a request is made only when
/// something is going to render it. Four requests for two blocks would be four
/// requests' worth of a field connection spent on nothing — and the price call
/// carries a commodity, so fetching it unasked would also pick a crop nobody
/// selected.
@Observable
@MainActor
final class DashboardStore {
    private(set) var ag: LoadState<AgDashboard> = .loading
    private(set) var taskTrend: LoadState<FarmTaskTrend> = .loading
    private(set) var briefing: LoadState<FieldBriefingPayload> = .loading
    private(set) var prices: LoadState<PricesResponse> = .loading

    /// The commodity the price block last loaded, so a change of crop refetches
    /// and an unchanged one does not.
    private var loadedCommodity: ChartableCommodity?

    private let preferences: DashboardPreferences

    /// NIL DEFAULT, resolved inside the initialiser — not `= .shared`.
    ///
    /// A default argument is evaluated AT THE CALL SITE, which is outside this
    /// class's `@MainActor` isolation, so `= .shared` warns: "main
    /// actor-isolated static property 'shared' can not be referenced from a
    /// nonisolated context; this is an error in the Swift 6 language mode".
    /// Resolved in the body instead, where the isolation already holds.
    ///
    /// It did not warn locally and did on CI — the runner is on an older Xcode
    /// than this machine, which the workflow prints a notice about for exactly
    /// this reason. It failed the warnings gate rather than the tests, which is
    /// the gate earning its keep: three source warnings against two known.
    init(preferences: DashboardPreferences? = nil) {
        self.preferences = preferences ?? .shared
    }

    /// Everything the current block selection needs, concurrently.
    ///
    /// `async let` rather than sequential awaits: four round trips on a field
    /// connection in series is four timeouts deep in the worst case, and none
    /// of them depends on another.
    func load() async { await load(showCachedFirst: true) }

    /// Pull-to-refresh. The screen already has content, so the cached copy is
    /// not republished under the reader's finger — the same rule
    /// `LocationsStore` records.
    func refresh() async { await load(showCachedFirst: false) }

    private func load(showCachedFirst: Bool) async {
        let wanted = Set(preferences.blocks)
        let commodity = preferences.priceCommodity

        async let agTask: Void = loadAg(if: wanted, showCachedFirst: showCachedFirst)
        async let trendTask: Void = loadTaskTrend(if: wanted, showCachedFirst: showCachedFirst)
        async let briefingTask: Void = loadBriefing(if: wanted, showCachedFirst: showCachedFirst)
        async let pricesTask: Void = loadPrices(
            if: wanted, commodity: commodity, showCachedFirst: showCachedFirst)

        _ = await (agTask, trendTask, briefingTask, pricesTask)
        loadedCommodity = wanted.contains(.grainPrice) ? commodity : nil
    }

    /// The ag payload feeds FOUR blocks, so it is fetched when any of them is
    /// on — and not four times.
    private func loadAg(if wanted: Set<DashboardBlock>, showCachedFirst: Bool) async {
        guard !wanted.isDisjoint(with: [.journal, .tasks, .lowStock, .achievements]) else { return }
        if ag.value == nil { ag = .loading }
        await CachedResource.loadShowingCacheFirst(
            DashboardAPI.agPath, showCachedFirst: showCachedFirst
        ) { data in
            try await DashboardAPI.decodeAg(from: data)
        } publish: { [weak self] in self?.ag = $0 }
    }

    /// FOURTEEN DAYS, named rather than omitted.
    ///
    /// Omitting `days` gives this route 14 and `/dashboard/trends` 90, so a
    /// screen that left both blank would be comparing a fortnight against a
    /// quarter. Only the task trend is drawn here — the owner chose the
    /// two-line chart over the ten-series one — so the window is stated to
    /// make it a decision rather than an inheritance.
    private func loadTaskTrend(if wanted: Set<DashboardBlock>, showCachedFirst: Bool) async {
        guard wanted.contains(.taskTrend) else { return }
        if taskTrend.value == nil { taskTrend = .loading }
        let path = DashboardAPI.taskTrendPath(days: DashboardAPI.DefaultWindow.tasks)
        await CachedResource.loadShowingCacheFirst(path, showCachedFirst: showCachedFirst) { data in
            try await DashboardAPI.decodeTaskTrend(from: data)
        } publish: { [weak self] in self?.taskTrend = $0 }
    }

    private func loadBriefing(if wanted: Set<DashboardBlock>, showCachedFirst: Bool) async {
        guard wanted.contains(.briefing) else { return }
        if briefing.value == nil { briefing = .loading }
        await CachedResource.loadShowingCacheFirst(
            DashboardAPI.fieldBriefingPath, showCachedFirst: showCachedFirst
        ) { data in
            try await DashboardAPI.decodeFieldBriefing(from: data)
        } publish: { [weak self] in self?.briefing = $0 }
    }

    /// THREE MONTHS of history for one number.
    ///
    /// The block shows the latest price, so a shorter range would do — but the
    /// range also decides which series look current, and `rankedForDefaultDisplay`
    /// ranks on `lastObservedAt`. A one-week window on a monthly feed returns a
    /// series with no points and a null observation date, which would rank last
    /// and hand the block a stale line while a fresher one existed. The range
    /// that answers "what is it worth today" is not the shortest one.
    private func loadPrices(if wanted: Set<DashboardBlock>,
                            commodity: ChartableCommodity,
                            showCachedFirst: Bool) async {
        guard wanted.contains(.grainPrice) else { return }
        if prices.value == nil || loadedCommodity != commodity { prices = .loading }
        let path = TrendsAPI.pricesPath(commodity, range: .month3)
        await CachedResource.loadShowingCacheFirst(path, showCachedFirst: showCachedFirst) { data in
            try await APIClient.shared.decode(data, as: PricesResponse.self)
        } publish: { [weak self] in self?.prices = $0 }
    }

    /// The one series the price block shows, and how many it stands for.
    ///
    /// Forwards to `PricesResponse.dashboardSeries`, which is where the rule
    /// lives so it can be tested without a loaded store — the selection is the
    /// part that can be wrong, and `prices` is `private(set)`.
    var chosenPriceSeries: (series: PriceSeries, outOf: Int)? {
        prices.value?.dashboardSeries
    }
}
