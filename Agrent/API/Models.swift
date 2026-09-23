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
    /// the point: it can be READ and never written. `NewEntryView` filters
    /// it out of the picker, and `selectable` is the list to use anywhere
    /// else a type is chosen rather than displayed.
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

enum LogEntryStatus: String, Codable, Sendable {
    case planned = "PLANNED"
    case done = "DONE"

    var label: String { self == .planned ? "Планирано" : "Готово" }
}

struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var type: LogEntryType
    var status: LogEntryStatus
    var title: String
    var notes: String?
    var occurredAt: Date
    /// Optimistic-concurrency counter. The server bumps it on every write and
    /// a replayed edit must send the version it SAW — see README, "Writes".
    var version: Int?
}

struct CreateLogEntry: Encodable, Sendable {
    var type: LogEntryType
    var status: LogEntryStatus = .done
    var title: String
    var notes: String?
    var occurredAt: Date?
}
