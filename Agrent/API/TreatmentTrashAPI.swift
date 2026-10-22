import Foundation

/// Removing a recorded treatment as a whole, putting it back, and «Кошче»
/// (agrent-ios #395; agri-saas #2175, #2184).
///
/// ── The whole treatment, never one parcel's row ──
///
/// The owner's ruling (2026-10-22): a swipe removes the WHOLE treatment, on
/// the phone as on the web. One treatment is a journal entry per parcel
/// across several blocks, and a row removed alone would leave its task, its
/// operation line and the other parcels' entries on a regulated register.
/// So the delete goes to the treatment's handle, the route `TreatmentAPI`
/// already abandons an unfinished one through (#326). Since #2184 that route
/// takes a complete treatment too.
///
/// ── Gone from the register too, and restorable ──
///
/// The server soft-deletes, and the ДНЕВНИК it prints leaves the treatment
/// out in both scopes, block and treatment (owner, 2026-10-22). The same
/// people who may remove it may restore it from «Кошче», and the server
/// audits each as its own event.
///
/// Never sent from development, CI or the screenshot harness: it changes a
/// farm's legal register. The seam answers every write with a refusal.
enum TreatmentTrashAPI {
    /// The «Кошче» listing: a STATIC segment beside the handle, which the
    /// server resolves first. A handle is a UUID or the phone's own key,
    /// never the word `deleted`.
    static var deletedPath: String { "\(TreatmentAPI.recordPath)/deleted" }

    /// POST, as the journal's own `/journal/{id}/restore` is.
    static func restorePath(_ handle: String) -> String {
        "\(TreatmentAPI.treatmentPath(handle))/restore"
    }

    /// One withdrawn treatment, folded on its handle: a treatment over three
    /// blocks is three tasks, and a «Кошче» listing it three times would
    /// offer three restores of one thing.
    ///
    /// Each row carries the treatment's summary, because a withdrawn handle
    /// stops resolving (`GET /journal/treatments/{handle}` answers 404), so
    /// nothing could be fetched per row to label it. `occurredOn` is the
    /// entry's day in the farm's zone, the one the journal list prints.
    /// Every field but the handle is read leniently: an odd one costs its
    /// line, never the row.
    struct Deleted: Decodable, Identifiable, Equatable, Sendable {
        let treatmentGroupId: String
        let deletedAt: Date?
        let deletedByUserId: String?
        let taskCount: Int
        /// `YYYY-MM-DD`, the farm's day.
        let occurredOn: String?
        var kind: String?
        var productName: String?
        var blockNames: [String]
        var parcelCount: Int?
        /// HECTARES, as stored. Shown in decares, through `Area`.
        var totalAreaHa: Double?
        /// Whether THIS person may put it back, under the restore's own two
        /// arms (creator or administrator, and a single author). Offered
        /// only where true: an offered restore that is refused is worse
        /// than none. Nil from a server older than the field.
        var mayRestore: Bool?

        var id: String { treatmentGroupId }
        var area: Area? { totalAreaHa.map(Area.init(hectares:)) }

        init(treatmentGroupId: String, deletedAt: Date? = nil, deletedByUserId: String? = nil,
             taskCount: Int = 1, occurredOn: String? = nil, kind: String? = nil,
             productName: String? = nil, blockNames: [String] = [], parcelCount: Int? = nil,
             totalAreaHa: Double? = nil, mayRestore: Bool? = nil) {
            self.treatmentGroupId = treatmentGroupId
            self.deletedAt = deletedAt
            self.deletedByUserId = deletedByUserId
            self.taskCount = taskCount
            self.occurredOn = occurredOn
            self.kind = kind
            self.productName = productName
            self.blockNames = blockNames
            self.parcelCount = parcelCount
            self.totalAreaHa = totalAreaHa
            self.mayRestore = mayRestore
        }

        private enum CodingKeys: String, CodingKey {
            case treatmentGroupId, deletedAt, deletedByUserId, taskCount, occurredOn
            case kind, productName, blockNames, parcelCount, totalAreaHa, mayRestore
        }

        /// Only the handle is load-bearing: it is what «Възстанови» sends.
        /// Everything else costs its line, never the row, so a withdrawn
        /// treatment cannot drop out of «Кошче» over one field.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            treatmentGroupId = try c.decode(String.self, forKey: .treatmentGroupId)
            deletedAt = ((try? c.decodeIfPresent(String.self, forKey: .deletedAt)) ?? nil)
                .flatMap(BgDate.parseInstant)
            deletedByUserId = (try? c.decodeIfPresent(String.self, forKey: .deletedByUserId)) ?? nil
            taskCount = (try? c.decodeIfPresent(Int.self, forKey: .taskCount)) ?? 1
            occurredOn = (try? c.decodeIfPresent(String.self, forKey: .occurredOn)) ?? nil
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
            productName = (try? c.decodeIfPresent(String.self, forKey: .productName)) ?? nil
            blockNames = (try? c.decodeIfPresent([String].self, forKey: .blockNames)) ?? []
            parcelCount = (try? c.decodeIfPresent(Int.self, forKey: .parcelCount)) ?? nil
            totalAreaHa = (try? c.decodeIfPresent(Double.self, forKey: .totalAreaHa)) ?? nil
            mayRestore = (try? c.decodeIfPresent(Bool.self, forKey: .mayRestore)) ?? nil
        }
    }

    private struct Listing: Decodable {
        let treatments: [Lossy]
    }

    /// One row that may not decode, without failing «Кошче». Only a row
    /// with no handle fails, and that one could not be restored anyway.
    private struct Lossy: Decodable {
        let value: Deleted?
        init(from decoder: Decoder) throws { value = try? Deleted(from: decoder) }
    }

    static func decodeList(from data: Data) throws -> [Deleted] {
        try JSONDecoder().decode(Listing.self, from: data).treatments.compactMap(\.value)
    }

    /// Newest first, as the server orders it: what somebody wants back is
    /// almost always what they just removed. At most `limit` rows and NOT
    /// paged, by the server's design: the screen undoes recent mistakes.
    /// Not cached: a «Кошче» read offline would offer restores that need the
    /// server anyway.
    static let limit = 200

    static func list() async throws -> [Deleted] {
        try decodeList(from: try await APIClient.shared.data(for: deletedPath))
    }

    /// The 200's counts aren't read: the row leaves «Кошче» and the journal
    /// is read again.
    static func restore(_ handle: String) async throws {
        _ = try await APIClient.shared.postReturningData(restorePath(handle), body: EmptyBody(), idempotencyKey: nil)
    }

    /// The route reads no body. No key either: a second restore of the same
    /// handle is the server's 404, which `isNotWithdrawn` reads as done.
    private struct EmptyBody: Encodable {}

    /// The route's own 404 on a restore: nothing WITHDRAWN under the handle.
    /// Restored from the web or another phone meanwhile, so it counts as done.
    static func isNotWithdrawn(_ error: Error) -> Bool {
        TreatmentAPI.isNothingRecorded(error)
    }
}
