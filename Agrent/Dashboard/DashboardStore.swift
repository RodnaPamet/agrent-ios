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
    /// «В страната» (#635): МЗХ's field-campaign progress.
    private(set) var campaign: LoadState<CampaignProgressResponse> = .loading

    // ── The revamped Табло (#671, owner 2026-11-17) ──

    /// Now and the coming days, from WeatherKit.
    private(set) var weather: LoadState<WeatherReport> = .loading
    /// 30 days measured and 7 ahead, mm a day, from Open-Meteo.
    private(set) var rainfall: LoadState<Rainfall> = .loading
    /// Where the two above are for: the phone rounded to ~5 km, or the farm.
    private(set) var place: WeatherPlace.Point?
    /// One tile per crop the farm grows, up to four (wheat when none).
    private(set) var cropTiles: [CropPriceTile] = []
    private var blocks: [Location] = []

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

        async let agTask: Void = loadAg(if: wanted, showCachedFirst: showCachedFirst)
        async let trendTask: Void = loadTaskTrend(if: wanted, showCachedFirst: showCachedFirst)
        async let briefingTask: Void = loadBriefing(if: wanted, showCachedFirst: showCachedFirst)

        async let campaignTask: Void = loadCampaign(if: wanted, showCachedFirst: showCachedFirst)

        async let weatherTask: Void = loadWeather(if: wanted)
        async let tilesTask: Void = loadCropTiles(if: wanted)

        _ = await (agTask, trendTask, briefingTask, campaignTask, weatherTask, tilesTask)
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

    /// Weather and rainfall share one place. The blocks are read only for
    /// the fallback; the phone's rounded position wins when there is one.
    private func loadWeather(if wanted: Set<DashboardBlock>) async {
        guard !wanted.isDisjoint(with: [.weather, .rainfall]) else { return }
        if blocks.isEmpty, let data = try? await APIClient.shared.data(for: LocationsAPI.listPath) {
            blocks = (try? await LocationsAPI.decodeList(from: data)) ?? []
        }
        guard let point = WeatherPlace.current(blocks: blocks) else {
            // No permission and no outlined block: nothing honest to show.
            if weather.value == nil { weather = .failed(DashboardWords.noPlace) }
            if rainfall.value == nil { rainfall = .failed(DashboardWords.noPlace) }
            return
        }
        await loadWeather(at: point, wanted: wanted)
    }

    private func loadWeather(at point: WeatherPlace.Point, wanted: Set<DashboardBlock>) async {
        place = point
        // Fetched side by side, published here on the main actor: the
        // sources are `Sendable` and return values, never touch this store.
        let weatherSource = WeatherSources.current
        let rainSource = RainfallSources.current
        async let report: Result<WeatherReport, Error>? = wanted.contains(.weather)
            ? await Self.capture { try await weatherSource.report(latitude: point.latitude, longitude: point.longitude) }
            : nil
        async let rain: Result<Rainfall, Error>? = wanted.contains(.rainfall)
            ? await Self.capture { try await rainSource.rainfall(latitude: point.latitude, longitude: point.longitude) }
            : nil
        switch await report {
        case .success(let r): weather = .loaded(r, .fresh)
        case .failure(let error): if weather.value == nil { weather = .failed(UserMessage.text(for: error)) }
        case nil: break
        }
        switch await rain {
        case .success(let r): rainfall = .loaded(r, .fresh)
        case .failure(let error): if rainfall.value == nil { rainfall = .failed(UserMessage.text(for: error)) }
        case nil: break
        }
    }

    /// `Result(catching:)` for an async call.
    private nonisolated static func capture<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    /// The phone's fix arrived (or moved a grid square) after the farm's
    /// weather was shown: show the phone's.
    func placeMayHaveChanged() async {
        let wanted = Set(preferences.blocks)
        guard !wanted.isDisjoint(with: [.weather, .rainfall]),
              let point = WeatherPlace.current(blocks: blocks), point != place else { return }
        await loadWeather(at: point, wanted: wanted)
    }

    /// The farm's own crops, by area, up to four — the ones Тенденции can
    /// chart. Wheat when the farm records none, so the block is never empty.
    private func loadCropTiles(if wanted: Set<DashboardBlock>) async {
        guard wanted.contains(.grainPrice) else { return }
        var commodities: [ChartableCommodity] = []
        if let data = try? await APIClient.shared.data(for: ParcelsByCropAPI.path),
           let totals = try? await ParcelsByCropAPI.decodeTotals(from: data) {
            let ranked = totals.crops.sorted { ($0.areaHaTotal ?? 0) > ($1.areaHaTotal ?? 0) }
            for crop in ranked {
                guard let slug = CommodityName.slug(freeText: crop.cropType),
                      let commodity = ChartableCommodity(rawValue: slug),
                      !commodities.contains(commodity) else { continue }
                commodities.append(commodity)
                if commodities.count == 4 { break }
            }
        }
        if commodities.isEmpty { commodities = [.wheat] }
        if cropTiles.map(\.commodity) != commodities {
            cropTiles = commodities.map { CropPriceTile(commodity: $0, state: .loading) }
        }
        for (index, commodity) in commodities.enumerated() {
            let path = TrendsAPI.pricesPath(commodity, range: .month3)
            await CachedResource.loadShowingCacheFirst(path, showCachedFirst: true) { data in
                try await APIClient.shared.decode(data, as: PricesResponse.self)
            } publish: { [weak self] state in
                guard let self, self.cropTiles.indices.contains(index),
                      self.cropTiles[index].commodity == commodity else { return }
                self.cropTiles[index].state = state
            }
        }
    }

    /// National figures, the same for every farm, so cached like any other.
    private func loadCampaign(if wanted: Set<DashboardBlock>, showCachedFirst: Bool) async {
        guard wanted.contains(.campaign) else { return }
        if campaign.value == nil { campaign = .loading }
        await CachedResource.loadShowingCacheFirst(
            CampaignProgressAPI.path, showCachedFirst: showCachedFirst
        ) { data in
            try await CampaignProgressAPI.decode(data)
        } publish: { [weak self] in self?.campaign = $0 }
    }
}

/// One price tile: a crop and its 3-month series (#671).
struct CropPriceTile: Equatable, Identifiable {
    let commodity: ChartableCommodity
    var state: LoadState<PricesResponse>
    var id: String { commodity.rawValue }
}
