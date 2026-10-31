import Foundation

/// The farm's document library (#468, agri-saas #2495): one row of it.
///
/// ── Decoded leniently, as every list here is ──
///
/// A field of an unexpected shape costs that field (`init(from:)`), and a
/// row without an `id` costs that row (`DocumentsAPI.decodeList`), never
/// the list.
///
/// ── Three ways a document can be gone ──
///
/// Expiry and a manual delete both leave the ROW (a tombstone, `purgedAt`),
/// so a deletion never looks like a document that was never uploaded
/// (owner, 2026-10-30). The bytes are gone either way; what differs is what
/// the row says (`DocumentRowText`). A manual delete clears the `name`.
struct FarmDocument: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// Nil on a document deleted by hand: the owner had the name cleared, as
    /// it is very often «the wrong file» and may name a third party.
    let name: String?
    let contentType: String?
    let sizeBytes: Int?
    let uploadedAt: Date?
    let uploadedBy: WorkItemSummary.Assignee?
    /// The farm's calendar day this document leaves Agrent's server,
    /// `YYYY-MM-DD` in the farm's zone, fixed at upload. Nil for «Без срок».
    /// A DAY, not an instant (agreed with backend 1): it is read with
    /// `BgDate.parseISODay` and nothing converts it across a time zone.
    let expiresOn: String?
    /// The period it was uploaded with, for «Пази се 1 година, до …».
    let retention: DocumentRetention?
    let purgedAt: Date?
    let purgeReason: PurgeReason?
    let purgedBy: WorkItemSummary.Assignee?
    /// The server's answer for THIS person. Read as `== false` hides it, as
    /// tasks do: absent offers it and the route's refusal is read out.
    let mayDelete: Bool?
    let drive: Drive?

    struct Drive: Decodable, Equatable, Sendable {
        let state: DriveState
    }

    enum DriveState: String, LenientDecodable, Sendable {
        case off = "OFF"
        case pending = "PENDING"
        case copied = "COPIED"
        case failed = "FAILED"
        case unknown = "UNKNOWN"

        static var unknownCase: Self { .unknown }
    }

    enum PurgeReason: String, LenientDecodable, Sendable {
        case expired = "EXPIRED"
        case deleted = "DELETED"
        case unknown = "UNKNOWN"

        static var unknownCase: Self { .unknown }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, contentType, sizeBytes, uploadedAt, uploadedBy, expiresOn, retention
        case purgedAt, purgeReason, purgedBy, mayDelete, drive
    }

    /// Only `id` is required. Every other field is read with `try?`, so one
    /// of an unexpected shape costs that field, not the row.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.recorded
        contentType = try? c.decodeIfPresent(String.self, forKey: .contentType)
        sizeBytes = try? c.decodeIfPresent(Int.self, forKey: .sizeBytes)
        uploadedAt = try? c.decodeIfPresent(Date.self, forKey: .uploadedAt)
        uploadedBy = try? c.decodeIfPresent(WorkItemSummary.Assignee.self, forKey: .uploadedBy)
        expiresOn = try? c.decodeIfPresent(String.self, forKey: .expiresOn)
        retention = try? c.decodeIfPresent(DocumentRetention.self, forKey: .retention)
        purgedAt = try? c.decodeIfPresent(Date.self, forKey: .purgedAt)
        purgeReason = try? c.decodeIfPresent(PurgeReason.self, forKey: .purgeReason)
        purgedBy = try? c.decodeIfPresent(WorkItemSummary.Assignee.self, forKey: .purgedBy)
        mayDelete = try? c.decodeIfPresent(Bool.self, forKey: .mayDelete)
        drive = try? c.decodeIfPresent(Drive.self, forKey: .drive)
    }

    /// Gone from Agrent: no preview, no delete, no Drive retry.
    var isPurged: Bool { purgedAt != nil || purgeReason != nil }

    var driveState: DriveState { drive?.state ?? .off }
}

/// How long a document is kept on Agrent's server (owner, 2026-10-30).
/// ISO-8601 periods on the wire, a closed set the server enforces; an
/// unknown value reads as `.unknown` and makes the picker read-only.
enum DocumentRetention: String, LenientDecodable, Sendable {
    case months3 = "P3M"
    case months6 = "P6M"
    case year1 = "P1Y"
    case years2 = "P2Y"
    case years5 = "P5Y"
    case none = "NONE"
    case unknown = "UNKNOWN"

    static var unknownCase: Self { .unknown }

    /// The choices, in the order the owner listed them.
    static let choices: [DocumentRetention] = [.months3, .months6, .year1, .years2, .years5, .none]

    var label: String {
        switch self {
        case .months3: "3 месеца"
        case .months6: "6 месеца"
        case .year1: "1 година"
        case .years2: "2 години"
        case .years5: "5 години"
        case .none: "Без срок"
        case .unknown: "—"
        }
    }

    /// The default for a farm that never chose (owner: 1 year).
    static let `default` = DocumentRetention.year1
}

struct DocumentsPage: Equatable, Sendable {
    let items: [FarmDocument]
    let truncated: Bool
}

/// The library's settings (#2495): what an admin may change, and how full
/// the farm's 2 GB is.
struct DocumentSettings: Decodable, Equatable, Sendable {
    let retention: DocumentRetention
    let driveSync: Bool
    let google: Google?
    let usedBytes: Int64
    let limitBytes: Int64
    /// OWNER and ADMIN: the two settings are theirs; others see them.
    let mayEdit: Bool

    struct Google: Decodable, Equatable, Sendable {
        let connected: Bool
        /// Not sent: the server deliberately withholds whose mailbox it is
        /// (agri-saas #2495, 2026-10-31). Kept optional in case that changes;
        /// the switch's line reads without it.
        let accountEmail: String?
    }

    private enum CodingKeys: String, CodingKey {
        case retention, driveSync, google, usedBytes, limitBytes, mayEdit
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retention = (try? c.decode(DocumentRetention.self, forKey: .retention)) ?? .unknown
        driveSync = (try? c.decode(Bool.self, forKey: .driveSync)) ?? false
        google = try? c.decodeIfPresent(Google.self, forKey: .google)
        usedBytes = (try? c.decode(Int64.self, forKey: .usedBytes)) ?? 0
        limitBytes = (try? c.decode(Int64.self, forKey: .limitBytes)) ?? 0
        mayEdit = (try? c.decode(Bool.self, forKey: .mayEdit)) ?? false
    }

    init(retention: DocumentRetention, driveSync: Bool, google: Google?,
         usedBytes: Int64, limitBytes: Int64, mayEdit: Bool) {
        self.retention = retention
        self.driveSync = driveSync
        self.google = google
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
        self.mayEdit = mayEdit
    }

    /// Whether a new upload will one day be deleted with no copy anywhere:
    /// the warning before an upload (owner, 2026-10-30).
    var uploadsExpireWithoutCopy: Bool {
        retention != .none && !(driveSync && google?.connected == true)
    }
}
