import Foundation

/// Mirrors `LogEntryType` in **prisma/schema/enums.prisma**.
///
/// NOT `journal.prisma` — this comment said that and it was wrong, and the
/// wrong citation is why the enum was never checked against the real one. The
/// app shipped SIX cases against the server's TEN, and invented an `OTHER` the
/// server has never had:
///
///     missing   SEEDING  TRANSPLANTING  IRRIGATION  LAB_TEST  GRAZING
///     invented  OTHER
///
/// `LogEntry.type` is non-optional, so ONE entry of an unknown type fails the
/// whole list decode — every entry disappears, not just that one. It had not
/// bitten yet only because the live tenant holds nothing but INPUT_APPLICATION
/// (9) and ACTIVITY (2); the first Сеитба or Напояване entry would have done
/// it. `OTHER` was the write-side twin: creating with it would have been
/// rejected by the server's enum.
/// ── Lenient since 2026-09-23, and the reason is asymmetry, not likelihood ──
///
/// This threw on an unrecognised value, and because `LogEntry.type` is
/// non-optional inside an array that failed the decode of the WHOLE journal
/// — every row vanishing, not the one. `LenientEnum.swift` recorded the
/// strictness as deliberate and said the decision should be taken on
/// purpose rather than as a side effect of a refactor. This is that
/// decision, taken on purpose.
///
/// The frequency argument favours strict and was checked rather than
/// assumed: the server enum has changed exactly ONCE, at feature
/// inception, and has held ten values since. Additions are rare.
///
/// The asymmetry beats it. An added value costs, leniently, one row showing
/// a fallback label. It costs, strictly, the entire ДНЕВНИК failing to
/// render — on a register a farmer is legally required to keep, at the
/// moment of a server deploy, with no client change and no warning.
///
/// And the coordination strictness relies on does not exist: adding a value
/// is a one-line schema change in a repo that contains no guard for what a
/// client decodes, and this app is not in that repo. "Rare AND coordinated"
/// was true about the first half only.
///
/// Same shape as `PagedResponse` refusing to return `[]` when it finds
/// neither `rows` nor `items`: the question is not how likely the failure
/// is, it is whether the failure is IN RANGE. An unknown value is in range
/// for the server and out of range for this decoder.
enum LogEntryType: String, Codable, CaseIterable, Identifiable, Sendable, LenientDecodable {
    case activity = "ACTIVITY"
    case observation = "OBSERVATION"
    case inputApplication = "INPUT_APPLICATION"
    case seeding = "SEEDING"
    case transplanting = "TRANSPLANTING"
    case harvest = "HARVEST"
    case irrigation = "IRRIGATION"
    case maintenance = "MAINTENANCE"
    case labTest = "LAB_TEST"
    case grazing = "GRAZING"

    /// A value this build does not know.
    ///
    /// The raw value is one the server will reject on a create, which is
    /// the point: it can be READ and never written. `selectable` is the
    /// list to use anywhere a type is chosen rather than displayed.
    case unknown = "__UNKNOWN__"

    static var unknownCase: LogEntryType { .unknown }

    /// Every type a PERSON may choose. Never `allCases` — that now
    /// includes `.unknown`, and offering it would let the app send a value
    /// the server has never heard of.
    static var selectable: [LogEntryType] { allCases.filter { $0 != .unknown } }

    var id: String { rawValue }

    /// Taken VERBATIM from the web app's `messages/bg.json`
    /// `journalEnums.logType.*`, so both clients name the same thing the same
    /// way to the same operator. (`INPUT_APPLICATION` read "Влагане" here and
    /// "Внасяне на препарат" there — the web app's wording wins.)
    var label: String {
        switch self {
        case .activity: "Дейност"
        case .observation: "Наблюдение"
        case .inputApplication: "Внасяне на препарат"
        case .seeding: "Сеитба"
        case .transplanting: "Разсаждане"
        case .harvest: "Прибиране на реколтата"
        case .irrigation: "Напояване"
        case .maintenance: "Поддръжка"
        case .labTest: "Лабораторен анализ"
        case .grazing: "Паша"
        // Deliberately vague, and deliberately not the raw value. A row
        // whose type this build does not know is still a real record with
        // a real date and real notes — it should read as an entry of a
        // kind this version cannot name, not as corrupt data, and
        // certainly not as `__UNKNOWN__`.
        case .unknown: "Друг вид"
        }
    }
}

enum LogEntryStatus: String, Codable, CaseIterable, Sendable, LenientDecodable {
    case planned = "PLANNED"
    case done = "DONE"
    /// A status this build does not know. The spec types `LogEntry.status`
    /// as a free string, not an enum, so a new value must cost one label —
    /// not, as it did, the whole ДНЕВНИК, which a single undecodable row
    /// fails (agrent-ios#182). Read, never written: like `LogEntryType
    /// .unknown`, the raw value is one the server would refuse, and nothing
    /// offers it — a new entry is `.done`.
    case unknown = "__UNKNOWN__"

    static var unknownCase: LogEntryStatus { .unknown }

    var label: String {
        switch self {
        case .planned: "Планирано"
        case .done: "Готово"
        case .unknown: "Друг статус"
        }
    }
}

/// One ДНЕВНИК entry as the server sends it.
///
/// ── `title` AND `occurredAt` ARE NULLABLE, as the spec has them ──
///
/// Both were non-optional here while the spec has them `string | null` and
/// neither required — the create request's `occurredAt` may be null too. One
/// such row, from the web or an import, failed the decode of the WHOLE list:
/// the register would show nothing at all rather than one entry without a
/// title (agrent-ios#182). The screens say what is missing instead —
/// `displayTitle`, `noDate`.
struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var type: LogEntryType
    var status: LogEntryStatus
    var title: String?
    var notes: String?
    var occurredAt: Date?
    /// Optimistic-concurrency counter. The server bumps it on every write and
    /// a replayed edit must send the version it SAW — see README, "Writes".
    var version: Int?
    /// The treatment this row STANDS FOR, when it is one (agri-saas #1799).
    /// The ДНЕВНИК list folds a treatment's one-entry-per-parcel into a
    /// single row, which keeps an entry's shape and carries the treatment
    /// here. Nil from every read that does not fold, and from an older server.
    var treatment: JournalTreatment? = nil

    /// The entry's title, or a word saying it has none — never a blank line
    /// where a farmer looks for what the record is.
    ///
    /// A folded treatment is titled by its PRODUCT. The entry under it is
    /// titled «{product} — {parcel}» for the one parcel that entry was
    /// written for, and on a row that stands for thirty parcels that names
    /// one of them as if it were the whole treatment.
    var displayTitle: String {
        if let product = treatment?.foldedProduct { return product }
        return title?.recorded ?? Self.untitled
    }

    static let untitled = "Без заглавие"
    static let noDate = "Без дата"
}

/// A folded ДНЕВНИК row's treatment (agri-saas #1799, `listJournalEntries`):
/// what the row shows beside an entry's own fields.
///
/// ── Never the reason a list fails ──
///
/// Every field is optional, and a value of the wrong shape reads as absent
/// rather than throwing: the Дневник is the launch screen, and one odd
/// treatment must not empty it — the rule `LogEntry`'s nullable title and
/// date already follow. Only the fields the row and the entry's screen
/// (`JournalDetailView`, #320) show are read.
struct JournalTreatment: Codable, Equatable, Sendable {
    var treatmentGroupId: String?
    var productName: String?
    /// Lines across every block. 0 for an entry that is no treatment — the
    /// server folds such an entry to itself and still sends this object.
    var parcelCount: Int
    var totalAreaHa: Double?
    var blockNames: [String]
    /// `YYYY-MM-DD`, from the quarantine period captured ON THE DAY (#1775).
    /// Null when no period was captured — never the treatment day itself.
    var earliestHarvestOn: String?
    /// The task's operation type: `SPRAY` or `FERTILIZE` for a treatment,
    /// which is the `kind` its write sent.
    var kind: String?
    /// A NUMBER on this route (`Number(line.doseValue)`), read through
    /// `WireDecimal` all the same, so neither shape costs the row.
    var doseValue: Decimal?
    /// The unit's SYMBOL, `л/дка` — not its name.
    var doseUnit: String?
    var targetNote: String?
    /// The slug — see `ApplicationTechnique`.
    var applicationTechnique: String?
    /// The period as it applied ON THE DAY (#1775), the one the ДНЕВНИК prints.
    var quarantinePeriodDays: Int?
    /// «Фенофаза/BBCH» as captured on the line (agri-saas #2083). No
    /// product fallback, unlike the period: nil means not captured, and
    /// nothing else can supply it.
    var phenophase: String?
    /// Whether THIS person may remove the treatment (agri-saas #2184),
    /// computed by the server from the predicate its route asserts with.
    /// Not a creator id: the rule is creator-or-administrator AND a single
    /// author across the treatment's tasks, which refuses administrators
    /// too, and no field on one row could say that. Advisory: the route
    /// checks again. Nil from a server, or a cached page, older than it.
    var mayDelete: Bool?
    /// Whether THIS person may correct it («Коригирай», agri-saas #2292).
    /// The same rule as `mayDelete` today, and deliberately its own field:
    /// see `TreatmentCorrection.offered`. Nil from a server, or a cached
    /// page, older than it.
    var mayCorrect: Bool?

    init(treatmentGroupId: String? = nil, productName: String? = nil, parcelCount: Int = 0,
         totalAreaHa: Double? = nil, blockNames: [String] = [], earliestHarvestOn: String? = nil,
         kind: String? = nil, doseValue: Decimal? = nil, doseUnit: String? = nil,
         targetNote: String? = nil, applicationTechnique: String? = nil,
         quarantinePeriodDays: Int? = nil, phenophase: String? = nil, mayDelete: Bool? = nil,
         mayCorrect: Bool? = nil) {
        self.treatmentGroupId = treatmentGroupId
        self.productName = productName
        self.parcelCount = parcelCount
        self.totalAreaHa = totalAreaHa
        self.blockNames = blockNames
        self.earliestHarvestOn = earliestHarvestOn
        self.kind = kind
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.targetNote = targetNote
        self.applicationTechnique = applicationTechnique
        self.quarantinePeriodDays = quarantinePeriodDays
        self.phenophase = phenophase
        self.mayDelete = mayDelete
        self.mayCorrect = mayCorrect
    }

    init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        treatmentGroupId = (try? c?.decodeIfPresent(String.self, forKey: .treatmentGroupId)) ?? nil
        productName = (try? c?.decodeIfPresent(String.self, forKey: .productName)) ?? nil
        parcelCount = (try? c?.decodeIfPresent(Int.self, forKey: .parcelCount)) ?? 0
        totalAreaHa = (try? c?.decodeIfPresent(Double.self, forKey: .totalAreaHa)) ?? nil
        blockNames = (try? c?.decodeIfPresent([String].self, forKey: .blockNames)) ?? []
        earliestHarvestOn = (try? c?.decodeIfPresent(String.self, forKey: .earliestHarvestOn)) ?? nil
        kind = (try? c?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        doseValue = ((try? c?.decodeIfPresent(WireDecimal.self, forKey: .doseValue)) ?? nil)?.value
        doseUnit = (try? c?.decodeIfPresent(String.self, forKey: .doseUnit)) ?? nil
        targetNote = (try? c?.decodeIfPresent(String.self, forKey: .targetNote)) ?? nil
        applicationTechnique = (try? c?.decodeIfPresent(String.self, forKey: .applicationTechnique)) ?? nil
        quarantinePeriodDays = (try? c?.decodeIfPresent(Int.self, forKey: .quarantinePeriodDays)) ?? nil
        phenophase = (try? c?.decodeIfPresent(String.self, forKey: .phenophase)) ?? nil
        mayDelete = (try? c?.decodeIfPresent(Bool.self, forKey: .mayDelete)) ?? nil
        mayCorrect = (try? c?.decodeIfPresent(Bool.self, forKey: .mayCorrect)) ?? nil
    }

    /// A row that stands for parcels, rather than an entry folded to itself.
    var isTreatment: Bool { parcelCount > 0 }

    /// The product, when this row is a treatment and names one.
    var foldedProduct: String? {
        guard isTreatment else { return nil }
        return productName?.recorded
    }

    var area: Area? { totalAreaHa.map(Area.init(hectares:)) }

    var earliestHarvest: Date? { earliestHarvestOn.flatMap(BgDate.parseISODay) }

    /// Spraying or fertilising, when the row says which.
    var treatmentKind: TreatmentDraft.Kind? { kind.flatMap(TreatmentDraft.Kind.init(rawValue:)) }

    /// «1,5 л/дка». Nil without a dose, so the fact is left out rather than
    /// shown as a «0» nobody set a boom to. Up to the column's four places,
    /// trailing zeros dropped, as `OperationLine.doseText` reads it.
    var doseText: String? {
        guard let doseValue else { return nil }
        let number = doseValue.formatted(
            .number.precision(.fractionLength(0...4)).grouping(.automatic).locale(BgDate.locale))
        guard let unit = doseUnit?.recorded else { return number }
        return "\(number) \(unit)"
    }

    /// The dose as VoiceOver should say it: the unit's NAME, which the row
    /// does not carry — only the symbol, which is spelled letter by letter.
    /// A unit outside the four is said as its symbol, never left out.
    var doseSpoken: String? {
        guard let text = doseText, let unit = doseUnit?.recorded,
              let name = Self.rateUnitNames[unit] else { return doseText }
        return text.replacingOccurrences(of: unit, with: name)
    }

    /// `/units?measure=RATE`: every unit a treatment's dose is entered in,
    /// by symbol (Tests/Fixtures/units-rate.json has them as served).
    static let rateUnitNames = [
        "л/дка": "литра на декар",
        "кг/дка": "килограма на декар",
        "мл/дка": "милилитра на декар",
        "г/дка": "грама на декар",
    ]
}

