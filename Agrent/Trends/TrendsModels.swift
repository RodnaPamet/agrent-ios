import Foundation

/// The commodities that actually have a price feed.
///
/// NINE, not the fifteen in `CommodityName.table`. `rapeseed`, `oats`,
/// `rye`, `soybean`, `peas` and `lentils` are real in the exchange
/// vocabulary and have no quotes behind them — the EC, Alpha Vantage and
/// Barchart feeds cover four crops. Asking for one is a 400, verified
/// against production rather than taken on trust:
///
///     rapeseed ERROR http(status: 400, code: nil, message: nil)
///
/// So the picker is driven from THIS list and `CommodityName` supplies only
/// the labels. Driving it from the name table would offer six entries whose
/// every outcome is an error, which reads as a broken page rather than as a
/// gap in the data.
enum ChartableCommodity: String, CaseIterable, Identifiable, Sendable {
    case wheat, maize, barley, sunflower
    case diesel, urea, dap, map
    case ammoniumNitrate = "ammonium-nitrate"

    var id: String { rawValue }

    /// Through `CommodityName`, which is where every crop name in this app
    /// resolves — the CI guard requires it and the reason is that a new
    /// render site printing the server's English is the failure mode.
    var label: String { CommodityName.canonical(rawValue) ?? rawValue }

    /// Crops and inputs are different questions — one is income and the
    /// other is cost — so the picker separates them rather than running
    /// nine entries together.
    var isInput: Bool {
        switch self {
        case .wheat, .maize, .barley, .sunflower: false
        case .diesel, .urea, .dap, .map, .ammoniumNitrate: true
        }
    }
}

enum PriceRange: String, CaseIterable, Identifiable, Sendable {
    case month1 = "1m"
    case month3 = "3m"
    case year1 = "1y"
    case all

    var id: String { rawValue }

    /// The server's own default, so opening the screen and changing nothing
    /// asks for what it would have given anyway.
    static let `default` = PriceRange.year1

    var label: String {
        switch self {
        case .month1: "1 мес."
        case .month3: "3 мес."
        case .year1: "1 год."
        case .all: "Всички"
        }
    }
}

struct PricePoint: Decodable, Equatable, Sendable {
    /// A CALENDAR DAY, `yyyy-MM-dd`, from a `@db.Date` column — so it is
    /// the stored day exactly and no timezone shift is possible unless this
    /// client introduces one. Parsed through `BgDate.parseISODay`.
    ///
    /// The column holds week-ending and month observations as well as days,
    /// because the EC feeds are weekly and Alpha Vantage is monthly. Points
    /// are therefore NOT evenly spaced and the gap between them varies by
    /// source — nothing here may infer a period from the spacing.
    let date: String

    /// A NUMBER on this endpoint. Elsewhere a Prisma Decimal arrives as a
    /// string; which one you get depends on whether the endpoint maps
    /// through `toDto`, so it is decided per endpoint and never globally.
    let price: Double

    /// Distinct-tenant sample size, present only on listings-derived
    /// series. Absent is normal and means "not that kind of series".
    let count: Int?

    var day: Date? { BgDate.parseISODay(date) }
}

struct PriceSeries: Decodable, Identifiable, Equatable, Sendable {
    let source: String
    let region: String
    let stage: String?
    let unit: String
    let currency: String
    let label: String?
    /// A calendar day, like `PricePoint.date` — NOT a timestamp, despite
    /// the `At` suffix.
    let lastObservedAt: String?
    let points: [PricePoint]

    /// STAGE IS PART OF THE IDENTITY, and the contract said (source, region).
    ///
    /// Production disagrees. Diesel returns four series from one source and
    /// two regions:
    ///
    ///     oil-bulletin BG without-tax  1216.62 EUR/1000l
    ///     oil-bulletin BG with-tax     1856.30 EUR/1000l
    ///     oil-bulletin EL without-tax  1286.96
    ///     oil-bulletin EL with-tax     ...
    ///
    /// Keyed on (source, region) the first two collide, and they differ by
    /// 639 EUR per 1000 litres — a little over fifty per cent. Picking
    /// either as "the" Bulgarian diesel price would misprice fuel by half
    /// on the screen a farmer uses to plan a season's costs.
    var id: String { "\(source)|\(region)|\(stage ?? "")" }

    /// The platform's typed price (agri-saas #1587; the owner's ruling,
    /// 2026-10-10, option A): published as its own series while it is in
    /// force, and absent from the payload once cleared. It is the price every
    /// farm's figures use that day, so where a screen shows ONE price it
    /// shows this one — across units and ahead of every observed series.
    /// Otherwise Табло could show the feed's price beside a calculator that
    /// uses the typed one: two prices for one commodity on one day.
    var isPlatformPrice: Bool { source == Self.platformSource }

    static let platformSource = "platform"

    /// What the series is called on screen. The platform's was typed, not
    /// observed, so it has no market label worth showing; the phone names it.
    var displayLabel: String? { isPlatformPrice ? "Въведена от Agrent" : label }

    /// «1216,62 евро на 1000 литра» — a price in this series' unit, for a
    /// screen that shows one number rather than a chart (Табло).
    ///
    /// Here rather than in the view so it can be tested: the view's own
    /// `currency/unit` interpolation read «EUR/EUR/1000l» for diesel and every
    /// other unit that carries its currency (#121), and nothing could see it.
    func headline(_ price: Double) -> String {
        "\(Num.text(price)) \(SeriesVocabulary.priceUnit(unit: unit, currency: currency))"
    }
}

extension Array where Element == PriceSeries {
    /// THE ONE SERIES a screen quotes (#409, owner 2026-10-23): the big price
    /// above Тенденции's chart, its one line, and Табло's price block. One
    /// rule, so the two screens cannot answer "the price of wheat" differently.
    ///
    /// The web's rule (agri-saas `trends-helpers.ts`: `selectPrimaryGroup`,
    /// `chartSeriesFor`, `leadSeriesOf`), in this order:
    ///
    /// 1. **Agrent's typed price**, whatever its unit or region: typed ALWAYS
    ///    wins until it is cleared (owner, 2026-10-10, #1587). Typed diesel is
    ///    per litre and the bulletin per 1000 litres, so ranking inside a group
    ///    would never see it.
    /// 2. **One group**, by (region, currency, unit), preferring Bulgaria, then
    ///    the EU average, then whichever group reported last. Grouped before
    ///    anything is compared, because wheat arrives in USD from Alpha Vantage
    ///    and EUR from the EC feed, and a "best" series across those would hand
    ///    back a number in another currency. A group of only our own listings is
    ///    a last resort: the median of our users' ASKING prices is not the
    ///    market.
    /// 3. **The national average** inside it, where EC publishes one (wheat,
    ///    maize, barley). EC quotes nine Bulgarian delivery points that disagree
    ///    by tens of euros, and a farm is not tied to one depot. The owner chose
    ///    it over the freshest quotation, which changes from week to week.
    /// 4. **Otherwise the freshest**, then the longest record, then the id, so
    ///    the choice is the same on every open for the same payload.
    ///
    /// Series with no points cannot lead: a screen quotes a latest price.
    func lead() -> PriceSeries? {
        let withPoints = filter { !$0.points.isEmpty }
        if let typed = withPoints.first(where: \.isPlatformPrice) { return typed }

        var order: [String] = []
        var groups: [String: [PriceSeries]] = [:]
        for series in withPoints {
            let key = "\(series.region.uppercased())|\(series.currency)|\(series.unit)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(series)
        }
        let all = order.compactMap { groups[$0] }
        let quotes = all.filter { !$0.allSatisfy { $0.source == SeriesSource.listingsSource } }
        let candidates = quotes.isEmpty ? all : quotes
        guard !candidates.isEmpty else { return nil }

        // Within a region — and as the last arm, across all of them — the
        // group whose best series is freshest. Never the server's order: two
        // Bulgarian groups (EUR and a national-currency listing) must resolve
        // the same way on every open.
        let regional = ["BG", "EU"].lazy
            .map { region in candidates.filter { $0.first?.region.uppercased() == region } }
            .first { !$0.isEmpty }
        guard let group = (regional ?? candidates).min(by: { Self.fresher($0.freshest(), than: $1.freshest()) })
        else { return nil }
        return group.first(where: SeriesSource.isNationalAverage) ?? group.freshest()
    }

    /// Most recently observed, then the longer record, then the id: a series
    /// observed last week says more about today than one that stopped in
    /// spring, and a tie must not resolve on the order the server sent.
    fileprivate static func fresher(_ left: PriceSeries?, than right: PriceSeries?) -> Bool {
        guard let left else { return false }
        guard let right else { return true }
        let l = left.lastObservedAt ?? "", r = right.lastObservedAt ?? ""
        if l != r { return l > r }
        if left.points.count != right.points.count { return left.points.count > right.points.count }
        return left.id < right.id
    }

    fileprivate func freshest() -> PriceSeries? {
        self.min { Self.fresher($0, than: $1) }
    }
}

/// How the lead price moved across the range on screen (#409): the owner
/// chose the change over the chosen period, so «1 мес.» shows the month's and
/// the number agrees with the line the farmer is looking at. The web's tile
/// shows week-over-week; this is a deliberate divergence (PARITY.md).
///
/// From the first point in the range to the latest, in per cent of the
/// first. Points are not evenly spaced (weekly EC, monthly Alpha Vantage), so
/// it is endpoints, never a rate.
struct PeriodChange: Equatable, Sendable {
    let percent: Double

    init?(_ series: PriceSeries) {
        let dated = series.points.compactMap { point in point.day.map { ($0, point.price) } }
            .sorted { $0.0 < $1.0 }
        guard dated.count >= 2, let first = dated.first?.1, let last = dated.last?.1, first != 0 else { return nil }
        percent = (last - first) / first * 100
    }

    /// Under a twentieth of a per cent reads «0,0 %» either way, so it is
    /// said as no change rather than as a rise of nothing.
    var isFlat: Bool { abs(percent) < 0.05 }

    /// «▲ 4,2 % за 1 година», «▼ 1,3 % за 3 месеца», «Без промяна за 1 месец».
    /// An arrow and a word, never a colour alone: a rise is good news for a
    /// crop and bad news for diesel, so the screen does not say which.
    func text(over range: PriceRange) -> String {
        if isFlat { return "Без промяна \(range.span)" }
        return "\(percent > 0 ? "▲" : "▼") \(Self.number(abs(percent))) % \(range.span)"
    }

    /// The same for VoiceOver, which reads «▲» as "black up-pointing triangle".
    func spoken(over range: PriceRange) -> String {
        if isFlat { return "Без промяна \(range.span)" }
        return "\(percent > 0 ? "Нагоре" : "Надолу") с \(Self.number(abs(percent))) процента \(range.span)"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(BgDate.locale))
    }
}

extension PriceRange {
    /// «за 1 месец» — what the change is measured over, in words.
    var span: String {
        switch self {
        case .month1: "за 1 месец"
        case .month3: "за 3 месеца"
        case .year1: "за 1 година"
        case .all: "за целия период"
        }
    }
}

struct PricesResponse: Decodable, Equatable, Sendable {
    let commodity: String
    let range: String
    /// A full instant, unlike every other date on this endpoint.
    let generatedAt: Date
    let series: [PriceSeries]
}

/// How old a series is, measured with two SERVER timestamps.
///
/// ── Why not the existing `Freshness` type ──
///
/// `Freshness` derives age from `Date()`, and reaching for it here is the
/// reflex this exists to stop. A rural device can be hours or days off; the
/// payload is Redis-cached for six hours; and the screen's whole job is to
/// tell a farmer how current a price is before they decide when to sell.
/// Deriving that from the phone's clock would let a wrong device clock
/// silently relabel a stale price as current. The server sends both ends of
/// the subtraction, so the phone's opinion about what time it is never
/// enters.
///
/// Computed in UTC on both sides: `generatedAt` is an instant and
/// `lastObservedAt` is a bare day, so they are only comparable in one fixed
/// zone, and the device's zone is exactly the input being excluded.
extension PricesResponse {
    /// The one series Тенденции and Табло quote — see `lead()`.
    var lead: PriceSeries? { series.lead() }

    /// How old the lead's last observation is, both ends server-side.
    var leadStaleDays: Int? {
        lead.flatMap { Staleness.days(generatedAt: generatedAt, lastObservedAt: $0.lastObservedAt) }
    }
}

enum Staleness {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Whole days between the last observation and the moment the payload
    /// was built. nil when the series has never been observed.
    static func days(generatedAt: Date, lastObservedAt: String?) -> Int? {
        guard let lastObservedAt, let observed = isoDay.date(from: lastObservedAt) else {
            return nil
        }
        let from = utc.startOfDay(for: observed)
        let to = utc.startOfDay(for: generatedAt)
        return utc.dateComponents([.day], from: from, to: to).day
    }

    /// Past this, the number gets said out loud rather than left for the
    /// reader to work out from a date.
    ///
    /// Not a hypothetical threshold: wheat's Alpha Vantage reference series
    /// was last observed 2026-07-01 against a payload generated
    /// 2026-09-22 — eighty-three days, sitting under a chart that otherwise
    /// looks entirely current.
    static let concerning = 21

    /// A SATELLITE PASS ages on a different clock, and 21 days is far too
    /// long for one.
    ///
    /// Sentinel-2 revisits every five days, so a gap past ten means cloud
    /// has been sitting over the field for two passes running — and a
    /// canopy decides a spray. The risk page was reading `concerning`
    /// above, which is a GRAIN PRICE threshold: it called a twelve-day-old
    /// image current while the parcel map, hard-coding ten, called the same
    /// image stale in orange. One fact, two screens, two answers.
    static let satellitePass = 10
}
