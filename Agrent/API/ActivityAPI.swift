import Foundation

/// Other work on parcels, recorded from «Нов запис» (#439):
/// `POST /journal/activities` (agri-saas, backend 1; owner 2026-10-25).
///
/// The treatments route's rules, minus the product half: the same
/// `Idempotency-Key`, which is the handle; a reused key REPLAYED; the same
/// date refusals. One day only, no range (owner). The route records and
/// completes in one call, so a harvest's quantity attaches at once.
///
/// Never sent from development, CI or the screenshot harness: it writes a
/// farm's register.
enum ActivityAPI {
    static func recordPath(tenant: String?) -> String {
        "\(FarmPath.root(for: tenant))/journal/activities"
    }

    /// One activity's page of «Дневник на стопанството» (#516, agri-saas
    /// #2700): the campaign register's renderer scoped to one handle. NOT
    /// the treatment's `farm-record`, which is Приложение 1, the БАБХ form
    /// with no row for a cultivation, a pruning or a harvest.
    static func diaryPath(_ handle: String) -> String {
        "\(recordPath(tenant: FarmPath.openSlug))/\(URLEscape.segment(handle))/campaign-diary"
    }

    /// That page as a local PDF for Quick Look, kept as every register is
    /// (`FarmRecordAPI.keep`): bytes inline, checked for `%PDF`, removed when
    /// the preview closes. A GET; the server files nothing.
    static func diary(forActivity handle: String) async throws -> URL {
        let (data, served) = try await APIClient.shared.getForDocument(diaryPath(handle))
        UsageEvents.note(.farmDiaryDownloaded)
        return try FarmRecordAPI.keep(
            data, named: FarmRecordAPI.fileName(served, fallback: "dnevnik-stopanstvo-\(handle).pdf"))
    }

    struct Body: Encodable, Equatable, Sendable {
        let kind: String
        let occurredOn: String
        let parcelIds: [String]
        /// Each parcel's area in hectares, as a treatment's: a whole parcel
        /// as its own exact area (owner, 2026-10-25), only one with no
        /// recorded area left out.
        let parcels: [TreatmentAPI.Body.ParcelArea]?
        /// A harvest's quantity in kg, one total for the activity, never
        /// split by parcel (owner, 2026-10-25). Nil on any other work.
        let harvestKg: Decimal?

        /// Nil for a record that isn't an activity.
        init?(_ record: TreatmentRecord) {
            guard let activity = record.activity else { return nil }
            kind = activity.rawValue
            occurredOn = BgDate.isoDay(record.date)
            parcelIds = record.parcelIDs
            let areas = record.parcelIDs.compactMap { id in
                (record.treatedAreas[id] ?? record.parcelAreas[id])
                    .map { TreatmentAPI.Body.ParcelArea(parcelId: id, treatedAreaHa: $0) }
            }
            parcels = areas.isEmpty ? nil : areas
            harvestKg = activity == .harvest ? record.harvestKg : nil
        }
    }

    static func record(_ record: TreatmentRecord, idempotencyKey: String) async throws -> TreatmentReceipt {
        guard let body = Body(record) else { throw NotAnActivity() }
        let data = try await APIClient.shared.postReturningData(
            recordPath(tenant: FarmPath.openSlug), body: body, idempotencyKey: idempotencyKey)
        UsageEvents.note(.activitySaved)
        return TreatmentAPI.receipt(from: data, key: idempotencyKey)
    }

    /// A treatment handed to the activities route: a bug, never a person's
    /// mistake, so it says nothing more.
    struct NotAnActivity: Error {}
}
