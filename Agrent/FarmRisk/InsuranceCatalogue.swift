import Foundation

/// The products and their tariffs, fetched rather than compiled in.
///
/// ── What this replaces, and why it was worth an endpoint ──
///
/// `InsurancePremium` carried a `provisionalTariffBp = 1000` and an eight-case
/// enum. That is a second description of one thing, and the asymmetry made it
/// worse than ordinary duplication: the SERVER recomputes from the four inputs
/// and its figure is what gets stored and emailed, so a stale local tariff
/// showed the farmer one number while the operator received another, with
/// nothing on either side able to say so.
///
/// The server session built this endpoint for exactly that reason — its own
/// description says "it exists for a SEPARATE codebase, where a compiled-in
/// tariff is a second description of one thing".
///
/// ── `?locale=bg`, EXPLICITLY — in the spec since agri-saas#1140 ──
///
/// The endpoint resolves names by `?locale=`, then a cookie, then `en`. It does
/// NOT read `Accept-Language`, which was changed at this app's request: this
/// phone reports `en_BG`, so negotiating from the device would have returned
/// English product names onto a screen that is Bulgarian by declaration —
/// arriving as DATA, where neither the `BgDate` guard nor the `CommodityName`
/// guard would have seen it.
///
/// The parameter WAS missing from the document — the operation listed only
/// `tenantSlug`, so a client generated from it would never send a locale and
/// would silently be served English. Reported, and fixed in agri-saas#1140:
/// `locale`, `in: query`, `required: false`, `enum: ['en','bg']` derived from
/// their `LOCALES` rather than restated, so a new language cannot leave the
/// document describing a narrower set than the server accepts.
///
/// Kept here rather than deleted because it is the SAME defect as the
/// `anyOf` omission on the lead request, one layer out: a missing `required`
/// hands the next client an error, while a missing query parameter hands them
/// English names as DATA — and data is the one route a localisation guard
/// cannot watch.
///
/// What detects it if English ever arrives anyway is
/// `labelsDisagreeingWithCommodityName` below, at RUNTIME. Not a test: a test
/// would compare a fixture written here against a mapping written here and
/// agree with itself, while the strings that matter come off a server.
struct InsuranceCatalogue: Decodable, Equatable, Sendable {

    /// WHICH ENGINE PRICED IT, for comparing rather than sending.
    ///
    /// The server session's note: "If it moves to 2 your local arithmetic has
    /// stopped matching what gets stored — that is the signal to stop
    /// previewing or to update."
    ///
    /// That is what makes a local preview defensible at all. Without it a
    /// stale phone shows a wrong figure indefinitely and nothing detects it;
    /// with it, the app can refuse to preview rather than preview wrongly. A
    /// visible refusal beats a silent wrong number, which is the same
    /// reasoning as showing the server's figure over ours on disagreement.
    let engineVersion: Int

    /// The tenant's own, so the app does not guess at a currency.
    let currencySymbol: String

    let products: [Product]

    /// `commodity` is the only optional field — a peril has no crop behind it.
    /// Everything else is in `required`.
    struct Product: Decodable, Equatable, Sendable, Identifiable {
        let key: String
        /// `crop` or `peril`. A STRING rather than an enum: the schema names
        /// two cases today and a third would otherwise fail the whole
        /// catalogue, which is this repo's standing rule about server enums.
        let kind: String
        let commodity: String?
        let tariffBp: Int
        let name: String
        let blurb: String

        var id: String { key }
        var isCrop: Bool { kind == "crop" }
    }

    /// THE ARITHMETIC THIS APP CAN STAND BEHIND.
    ///
    /// `InsurancePremium`'s formula was written against engine 1. When the
    /// server moves past it the local preview is no longer what gets stored,
    /// so the form stops previewing and says so instead of showing a figure it
    /// cannot defend.
    static let arithmeticWrittenForEngine = 1

    var matchesLocalArithmetic: Bool {
        engineVersion == Self.arithmeticWrittenForEngine
    }

    func product(key: String) -> Product? { products.first { $0.key == key } }

    /// Crop products whose fetched name disagrees with `CommodityName`.
    ///
    /// ── Why this is a runtime check and not only a test ──
    ///
    /// Five of the products are commodities and this app already has a
    /// Bulgarian name for each. If the catalogue's name for `wheat` is not
    /// ours, the insurance picker shows one word and every other screen shows
    /// another — worse than either alone.
    ///
    /// A unit test cannot catch that. It would compare a fixture I wrote
    /// against a mapping I wrote, and agree with itself: the strings that
    /// matter arrive from a server at runtime. So the comparison happens when
    /// the catalogue lands, and a disagreement is logged.
    ///
    /// The server pinned the same equality in its own docblock, with the
    /// instruction to change `insurance.products.<key>.name` in `messages/` so
    /// both follow rather than hardcoding either side.
    var labelsDisagreeingWithCommodityName: [(key: String, fetched: String, ours: String)] {
        products.compactMap { product in
            guard let commodity = product.commodity,
                  let ours = CommodityName.canonical(commodity),
                  ours != product.name
            else { return nil }
            return (product.key, product.name, ours)
        }
    }
}

enum InsuranceCatalogueAPI {
    /// `?locale=bg` because the app is Bulgarian by declaration, never by what
    /// the device reports. The default is `en` deliberately, so a client that
    /// forgets to declare is wrong loudly — this one declares.
    static var path: String { "/api/t/\(Config.tenantSlug)/insurance/products?locale=bg" }

    static func decode(_ data: Data) async throws -> InsuranceCatalogue {
        try await APIClient.shared.decode(data, as: InsuranceCatalogue.self)
    }
}
