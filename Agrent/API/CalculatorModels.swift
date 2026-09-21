import Foundation

/// The grain calculator payload.
///
/// Modelled from `Tests/Fixtures/calculator-sample.json` — the output of the
/// server's real `buildCalculatorPayload()` — rather than from a description
/// of it. Production returns an EMPTY payload for this tenant (zero Seasons,
/// zero Plantings, zero CropPlans), so the wire cannot exercise any of the
/// element types below and the fixture is the only evidence there is.
///
/// TWO DATE SPELLINGS IN ONE PAYLOAD, and neither is a `Date`:
///
///     generatedAt      "2026-09-21T15:04:09.618Z"   full ISO, fractional
///     priceObservedAt  "2026-09-18"                 DATE ONLY, yyyy-mm-dd
///
/// `APIClient`'s decoder accepts ISO 8601 with and without fractional seconds
/// and NOTHING else, so typing `priceObservedAt` as `Date` fails the WHOLE
/// payload — every row gone, not just that field. Both stay `String`. The
/// journal's `occurredAt` genuinely is a `Date` and keeps that treatment; this
/// payload only looks similar.
struct CalculatorPayload: Decodable, Equatable, Sendable {
    let generatedAt: String
    let seasonId: String?
    let rows: [CalculatorRow]
    let farm: FarmSummary
    let exclusions: Exclusions
    let unvalued: UnvaluedCounts
    let cashOut: [CashOutBucket]
    let unallocatedToCrop: UnallocatedToCrop
    let imputedLandCharge: ImputedLandCharge
    let truncated: Bool
}

/// How much to trust a figure.
///
/// The server's vocabulary, all lowercase, from `uncertainty.ts:31-44`:
///
///     exact  atLeast  atMost  allocated  partial  refused
///
/// A NOTE ON A RETRACTED CLAIM, because it was committed and pushed. An
/// earlier version of this file recorded that the payload used TWO casing
/// conventions — lowercase for `netUncertainty`/`costUncertainty` and
/// UPPERCASE for `perArea`/`breakEven` — and said it was "measured, not
/// assumed". That was wrong. It was measured, but against a fixture whose
/// seed had those values hand-written; the mapper passed them through
/// verbatim and the defect looked exactly like a server inconsistency. The
/// server has one vocabulary and there is nothing to fix on it.
///
/// Matching stays case-insensitive anyway, as cheap defence — but it is
/// defence against a hypothetical, NOT a workaround for observed behaviour,
/// and nobody should read it as evidence the server is inconsistent.
///
/// `.unknown` is the part that matters and is unaffected. `LogEntryType`
/// shipped six cases against the server's ten, and because that field is a
/// non-optional enum ONE unrecognised value would have failed the entire list
/// decode — every row vanishing, not just the odd one. A server that adds an
/// uncertainty level should cost us a vague label on one figure, not a blank
/// screen.
enum Uncertainty: String, CaseIterable, LenientDecodable, Sendable {
    static var unknownCase: Uncertainty { .unknown }

    case exact
    case atLeast
    case atMost
    case allocated
    case partial
    case refused
    /// Anything the server adds that this build has not heard of.
    case unknown

}

struct CalculatorRow: Decodable, Equatable, Sendable, Identifiable {
    let commodity: String
    let pricePerTonne: Double?
    let priceCurrency: String?
    /// yyyy-mm-dd. NOT a `Date` — see the type header.
    let priceObservedAt: String?
    let priceSource: String?

    let standingCropAreaHa: Double
    let standingCropExpectedKg: Double
    let standingCropValue: Double?

    let perArea: PerArea
    let breakEven: BreakEven

    let grainOnHandTonnes: Double
    let grainOnHandValue: Double?
    let rentCostProduceKg: Double
    let rentCostProduceValue: Double?

    let payrollAllocated: Bool
    let cashCostTotal: Double
    let unvaluedNoUnitCost: Int
    let unvaluedUnitMismatch: Int

    let netWorth: Double?
    /// Already a human sentence from the server. `netWorthUnavailableCode` and
    /// `…Params` are deliberately NOT modelled: they exist for the web's i18n,
    /// this app hard-codes Bulgarian, and `Params` is an open-ended object
    /// whose value types are unobserved. Decodable ignores keys it is not
    /// asked for, so leaving them out is safer than guessing at them — a wrong
    /// guess there fails the whole payload.
    let netWorthUnavailableReason: String?

    let netUncertainty: Uncertainty
    let costUncertainty: Uncertainty
    let costCurrencyCodes: [String]
    let rentCurrencyUnknown: Bool
    let showProduceRent: Bool
    let costBreakdown: [CostSlice]

    var id: String { commodity }

    /// Expected tonnage, derived rather than requested.
    ///
    /// The web computes this client-side too (`CalculatorClient.tsx:473`), so
    /// deriving it matches rather than diverges.
    var expectedTonnes: Double { standingCropExpectedKg / 1000 }
}

/// Per-decare figures.
///
/// USE `areaDca` FROM HERE. Do not recompute it from `standingCropAreaHa`:
/// the web does exactly that at `CalculatorClient.tsx:472` via an UNROUNDED
/// `haToDca`, while this field is rounded to 2dp at `per-area.ts:82`. The web
/// therefore carries two values of the same name that differ, and every
/// per-dca figure here was computed against THIS one — so anything displayed
/// beside them has to match it.
struct PerArea: Decodable, Equatable, Sendable {
    let areaDca: Double
    let standingValuePerDca: Double?
    let attributableCostPerDca: Double?
    let marginPerDca: Double?
    let uncertainty: Uncertainty
    let refusalCode: String?
}

struct BreakEven: Decodable, Equatable, Sendable {
    let breakEvenPricePerTonne: Double?
    let marketPricePerTonne: Double?
    let currency: String?
    let coverPercent: Double?
    let covered: Bool?
    let uncertainty: Uncertainty
    let refusalCode: String?
}

struct CostSlice: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let labelKey: String
    let value: Double
    let variant: String
}

/// `refusedWithoutCurrency` is NOT modelled: it is empty in both the fixture
/// and production, so its element type has never been observed. Guessing at
/// it is the `LogEntryType` mistake — a wrong element type fails the whole
/// payload. It can be added the moment something populates it.
struct FarmSummary: Decodable, Equatable, Sendable {
    let totals: [FarmTotal]
}

struct FarmTotal: Decodable, Equatable, Sendable, Identifiable {
    let currency: String
    let netWorth: Double
    let refusedCommodities: [String]

    var id: String { currency }
}

struct ExclusionItem: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
}

/// Nine buckets of "what this figure could not account for".
///
/// Only two are populated in the fixture and none in production, so seven
/// element types rest on the two that were observed. They are decoded
/// LENIENTLY for that reason: an element that does not match `ExclusionItem`
/// is dropped rather than failing the payload, so a surprise in a footnote
/// cannot take the whole calculator down with it.
struct Exclusions: Decodable, Equatable, Sendable {
    let plantingsMissingYieldEstimate: [ExclusionItem]
    let plantingsUnknownCommodity: [ExclusionItem]
    let lotsUnresolvedUnit: [ExclusionItem]
    let lotsUnknownCommodity: [ExclusionItem]
    let commoditiesWithNoPrice: [ExclusionItem]
    let leasesUnresolvedRent: [ExclusionItem]
    let leasesUnattributed: [ExclusionItem]
    let leasesProduceRentUnpriced: [ExclusionItem]
    let payrollUnattributable: [ExclusionItem]

    var isEmpty: Bool { all.isEmpty }

    var all: [ExclusionItem] {
        plantingsMissingYieldEstimate + plantingsUnknownCommodity
            + lotsUnresolvedUnit + lotsUnknownCommodity + commoditiesWithNoPrice
            + leasesUnresolvedRent + leasesUnattributed
            + leasesProduceRentUnpriced + payrollUnattributable
    }

    /// Declared explicitly: writing `init(from:)` suppresses the synthesized
    /// `CodingKeys`, so without this the compiler reports
    /// "cannot find 'CodingKeys' in scope".
    private enum CodingKeys: String, CodingKey {
        case plantingsMissingYieldEstimate
        case plantingsUnknownCommodity
        case lotsUnresolvedUnit
        case lotsUnknownCommodity
        case commoditiesWithNoPrice
        case leasesUnresolvedRent
        case leasesUnattributed
        case leasesProduceRentUnpriced
        case payrollUnattributable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func lenient(_ key: CodingKeys) -> [ExclusionItem] {
            guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
            var items: [ExclusionItem] = []
            while !list.isAtEnd {
                if let item = try? list.decode(ExclusionItem.self) {
                    items.append(item)
                } else {
                    // Skip the element without aborting: decoding a throwaway
                    // advances the container past it.
                    _ = try? list.decode(AnySkipped.self)
                }
            }
            return items
        }
        plantingsMissingYieldEstimate = lenient(.plantingsMissingYieldEstimate)
        plantingsUnknownCommodity = lenient(.plantingsUnknownCommodity)
        lotsUnresolvedUnit = lenient(.lotsUnresolvedUnit)
        lotsUnknownCommodity = lenient(.lotsUnknownCommodity)
        commoditiesWithNoPrice = lenient(.commoditiesWithNoPrice)
        leasesUnresolvedRent = lenient(.leasesUnresolvedRent)
        leasesUnattributed = lenient(.leasesUnattributed)
        leasesProduceRentUnpriced = lenient(.leasesProduceRentUnpriced)
        payrollUnattributable = lenient(.payrollUnattributable)
    }

    private struct AnySkipped: Decodable {}
}

struct UnvaluedCounts: Decodable, Equatable, Sendable {
    let noUnitCost: Int
    let unitMismatch: Int

    var isClean: Bool { noUnitCost == 0 && unitMismatch == 0 }
}

struct CashOutBucket: Decodable, Equatable, Sendable, Identifiable {
    let currency: String
    let amount: Double
    let categories: [String]

    var id: String { currency }
}

struct UnallocatedToCrop: Decodable, Equatable, Sendable {
    let amount: Double
    let areaHa: Double
    let parcelIds: [String]
    let currencies: [String]
}

struct ImputedLandCharge: Decodable, Equatable, Sendable {
    let perHa: Double?
    let areaHa: Double
    let totalAmount: Double
    let refusalCode: String?
}
