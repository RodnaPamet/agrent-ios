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
enum Staleness {
    private static var utc: Calendar = {
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
