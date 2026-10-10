import Foundation

/// The superuser's daily prices (#258), against agri-saas #1587 contract v1.2,
/// as built in agri-saas #1618.
///
/// The owner, 2026-10-10: price fields, filled daily, that update the price
/// for every farm. A typed price ALWAYS wins over the API's for its commodity
/// until it is cleared, in the calculator, the net worth and contracts alike.
///
/// ── Global, so gated twice on the server ──
///
/// `MarketPriceSeries` has no tenant: every farm reads the same rows. The
/// routes sit under the platform farm's `/admin` and need both `admin.manage`
/// and the platform-farm check (`assertPlatformSupport`). Anywhere else they
/// answer 404. The phone only decides whether to OFFER the screen.
///
/// ── Never sent from here, outside the owner's own hands ──
///
/// A price typed here changes every farm's figures. Nothing in development,
/// CI or A11yShots sends one; the fixtures answer the reads, and the owner
/// makes the first entry.
enum AdminPricesAPI {
    private static var base: String { "\(FarmPath.root)/admin/market-prices/overrides" }

    static var path: String { base }

    static func clearPath(_ commodity: String) -> String {
        "\(base)/\(URLEscape.segment(commodity))"
    }

    /// The ten the owner chose (2026-10-10), in the form's two runs. The
    /// server lists the rows; this only orders and groups them, and a
    /// commodity the server adds that is not here goes at the end of the
    /// second run rather than disappearing.
    static let crops = ["wheat", "barley", "maize", "sunflower", "rapeseed"]
    static let inputs = ["urea", "ammonium-nitrate", "map", "dap", "diesel"]

    // MARK: - The form's read

    /// `GET …/overrides`: per commodity, the price typed (if any), the API's
    /// latest (if any), and which feed the API would be (`apiFeed`).
    struct Overrides: Decodable, Equatable, Sendable {
        let commodities: [Row]

        struct Row: Decodable, Equatable, Sendable, Identifiable {
            let commodity: String
            let typed: Quote?
            let api: Quote?
            let apiFeed: Feed
            /// What a figure is typed in: `EUR/t`, or `EUR/l` for diesel
            /// (contract v1.2). Read off the payload, never restated here: a
            /// second copy of this split is a price wrong by 1000× that looks
            /// like an ordinary number, and no guard sees both repos. A label
            /// and a sanity-check hint only; the server derives the stored
            /// unit itself and refuses one from a client.
            let entryUnit: String
            let entryCurrency: String

            var id: String { commodity }
        }

        /// One price as stored: the value, its denomination, and its day.
        struct Quote: Decodable, Equatable, Sendable {
            let value: WireDecimal
            let currency: String
            let unit: String
            /// `YYYY-MM-DD`. A day, not an instant: see `BgDate.parseISODay`.
            let date: String
            /// The API's source on `api`; absent on `typed`.
            let source: String?
        }

        /// Where the API price would come from.
        ///
        /// `none` is a CLAIM, not an absence. It means no feed exists for the
        /// commodity at all, so the typed price is the only price any farm
        /// sees, and clearing it leaves the calculator with none. `api: nil`
        /// with a real feed says something else: the feed exists and has no
        /// current point. The form says the two differently (agri-saas #1587).
        enum Feed: String, LenientDecodable, Sendable {
            case ecAgrifood = "ec-agrifood"
            case worldBank = "world-bank"
            case oilBulletin = "oil-bulletin"
            case none
            case unknown = "__UNKNOWN__"

            static var unknownCase: Self { .unknown }

            /// Whether an API price can exist for this commodity at all.
            var exists: Bool { self != .none }
        }
    }

    static func load() async throws -> Overrides {
        let data = try await APIClient.shared.data(for: path)
        return try await APIClient.shared.decode(data, as: Overrides.self)
    }

    // MARK: - The day's prices

    /// One day's prices, all or nothing. Unit and currency are NOT sent: the
    /// server derives them per commodity (EUR/t; diesel EUR/l) and refuses to
    /// take them from a client, so no caller can put a per-tonne figure into
    /// the litre series (#1587 §5d).
    struct Day: Encodable, Equatable, Sendable {
        let date: String
        let prices: [Price]

        struct Price: Encodable, Equatable, Sendable {
            let commodity: String
            /// A JSON number, from a `Decimal`: no binary rounding on the way.
            let value: Decimal
        }
    }

    /// The request body: the day, plus the key it was minted under, in the
    /// body and the header alike. The server RECORDS the key and does not
    /// dedupe on it (agri-saas #1618): the price tables are global, with no
    /// tenant to scope a key by, and need none — each price upserts on its
    /// series and date, so a day sent twice leaves the same prices. A retry
    /// over a bad link is safe by construction.
    private struct Body: Encodable {
        let date: String
        let prices: [Day.Price]
        let clientMutationId: String
    }

    struct Written: Decodable, Equatable, Sendable {
        let written: Int
    }

    /// `key` comes from `CostIdempotencyKey.mint(nonce:draft:)` over `day`:
    /// the same day, the same key, for the audit row to tie the two together.
    static func save(_ day: Day, key: String) async throws -> Written {
        try await APIClient.shared.post(
            path, body: Body(date: day.date, prices: day.prices, clientMutationId: key),
            as: Written.self, idempotencyKey: key
        )
    }

    // MARK: - Clearing

    /// Ends one commodity's override, in every region and stage. The server
    /// marks the series and its points cleared and keeps them, so the history
    /// survives (#1587 §5b); a later price starts a fresh run, and only the
    /// days typed again rejoin it. Clearing nothing is a 200 with
    /// `cleared: false`, so a retried clear is not an error.
    static func clear(_ commodity: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(clearPath(commodity))
    }
}
