import XCTest
@testable import Agrent

/// WHAT EACH MODEL REFUSES TO DECODE WITHOUT, proved by removing it.
///
/// ── The defect this exists to catch, three times over ──
///
/// A field declared non-optional in Swift that the server does not require is
/// the most expensive shape this repo has: one row fails, the array fails, and
/// the whole screen goes to an error state over a value nobody was reading.
/// It has happened four times in a week — `WorkItemSummary.key` and
/// `.severity` (the Задачи tab), `Location.kind` and `.createdAt` (Локации),
/// `ParcelHistoryOperation.doseValue` (the parcel archive), and
/// `CostSlice.variant` (every cost, every crop and the net worth, over a
/// colour the app does not render).
///
/// ── Why the fixtures could not catch any of them ──
///
/// Every one was invisible for the same reason, and it is not a type hole:
///
///     every operation fixture was a SPRAY          so a null dose never appeared
///     the milestone test injected ONE unknown key  so two colliding ids never appeared
///     every calculator slice carried a `variant`   so an absent variant never appeared
///
/// Perfectly valid fixtures that simply never contain the hard case. Nothing
/// detects that by reading them — the only defence is asking what a fixture
/// does NOT contain, and this file asks it mechanically: it takes one complete
/// payload per model and removes each key in turn.
///
/// ── What it measures, and what that is not ──
///
/// For every top-level key it produces two variants — key ABSENT, and key set
/// to NULL — and records whether the model still decodes. The result is the
/// set of keys the model genuinely cannot do without.
///
/// That set is asserted against a literal below. The literal is not a
/// preference: it was seeded from the OpenAPI `required` lists, so a red test
/// means either the model drifted or the contract did, and both are worth
/// stopping for. Adding a model here forces somebody to look up what the
/// server actually requires, which is the step that was skipped each of the
/// four times.
///
/// NESTED objects are not mutated. The failures above were all top-level, and
/// a check that recursed would take an argument about which sub-object is
/// worth a fixture; this one stays a flat, readable claim per model.
final class DecoderToleranceTests: XCTestCase {

    /// One model, one complete payload, and a way to decode it.
    ///
    /// The closure captures the type, so the list can hold models with nothing
    /// in common. It returns nothing: only whether it threw is interesting.
    struct Probe {
        let model: String
        let json: String
        let decode: (Data) async throws -> Void

        init(_ model: String, _ json: String,
             _ decode: @escaping (Data) async throws -> Void) {
            self.model = model
            self.json = json
            self.decode = decode
        }
    }

    // MARK: - The payloads

    static let probes: [Probe] = [
        Probe("CropSeason", #"""
        {"id":"cs","year":2026,"cropType":"Wheat","sownAt":"2025-10-14T00:00:00.000Z",
         "harvestedAt":"2026-07-02T00:00:00.000Z","notes":"късна"}
        """#) { _ = try await APIClient.shared.decode($0, as: CropSeason.self) },

        Probe("ParcelHistoryOperation", #"""
        {"id":"op","taskId":"t","operationType":"SPRAY","title":"Хербицид",
         "completedAt":"2026-05-03T06:12:00.000Z","productName":"Раундъп",
         "doseValue":"2.5","doseUnit":"л/дка","targetNote":"балур",
         "productCategory":"PESTICIDE"}
        """#) { _ = try await APIClient.shared.decode($0, as: ParcelHistoryOperation.self) },

        Probe("WeedObservation", #"""
        {"id":"wo","observedAt":"2026-06-11T05:40:00.000Z",
         "weedKeys":["Galium aparine"],"otherWeeds":["друг"],"notes":"бележка"}
        """#) { _ = try await APIClient.shared.decode($0, as: WeedObservation.self) },

        Probe("WorkItemSummary", #"""
        {"id":"t1","key":"AGT-1","title":"Пръскане","type":"FIELD_OPERATION",
         "status":"OPEN","severity":"HIGH","dueAt":"2026-09-30T00:00:00.000Z",
         "assignee":null,"assigneeUserId":null,
         "createdAt":"2026-09-01T10:00:00.000Z","updatedAt":"2026-09-01T10:00:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: WorkItemSummary.self) },

        Probe("Location", #"""
        {"id":"loc","tenantId":"t","name":"Долен блок","status":"ACTIVE",
         "kind":"FIELD","description":null,"capacityTonnes":null,
         "createdAt":"2026-09-01T10:00:00.000Z","updatedAt":null,
         "boundsJson":null,"_count":{"parcels":3}}
        """#) { _ = try await APIClient.shared.decode($0, as: Location.self) },

        Probe("CostSlice", #"""
        {"id":"s","labelKey":"costRentLabel","value":1234.5,"variant":"warning"}
        """#) { _ = try await APIClient.shared.decode($0, as: CostSlice.self) },

        Probe("AgDashboard.JournalItem", #"""
        {"id":"j","type":"HARVEST","title":"Жътва","occurredAt":"2026-07-02T09:00:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: AgDashboard.JournalItem.self) },

        Probe("AgDashboard.LowStockItem", #"""
        {"id":"s1","name":"Раундъп","quantityOnHand":1.15,"unitSymbol":"л"}
        """#) { _ = try await APIClient.shared.decode($0, as: AgDashboard.LowStockItem.self) },

        Probe("AgDashboard.TaskItem", #"""
        {"id":"t","title":"Пръскане","status":"OPEN","dueAt":null}
        """#) { _ = try await APIClient.shared.decode($0, as: AgDashboard.TaskItem.self) },

        Probe("FarmTaskTrendPoint", #"""
        {"date":"2026-09-25","created":3,"completed":1}
        """#) { _ = try await APIClient.shared.decode($0, as: FarmTaskTrendPoint.self) },

        Probe("BriefingAction", #"""
        {"field":"Долен блок","action":"Провери влагата","priority":"high"}
        """#) { _ = try await APIClient.shared.decode($0, as: BriefingAction.self) },

        Probe("ImportJobStatus", #"""
        {"jobId":"job","state":"active","failedReason":null,"result":null}
        """#) { _ = try await APIClient.shared.decode($0, as: ImportJobStatus.self) },

        // ── Added 2026-09-26, and the reason is the point ──
        //
        // `Parcel` was not in this list. Twenty models were "covered" and the
        // one behind the parcel map and the parcel list was not one of them —
        // a count that looks like coverage until you ask what it ranged over.
        // It came up because `absentFromImportAt` arrived and wanted a probe.
        Probe("Parcel", #"""
        {"id":"p1","name":"15655-19","cropType":"wheat","areaHa":12.4,
         "geometry":{"type":"MultiPolygon","coordinates":[[[[24.20,43.11],
           [24.21,43.11],[24.21,43.12],[24.20,43.11]]]]},
         "soilType":"Чернозем","cadastralId":"15655.19","ekatte":"15655",
         "hasActiveLease":true,"absentFromImportAt":null}
        """#) { _ = try await APIClient.shared.decode($0, as: Parcel.self) },

        // The executor envelope, shared by spatial-import and cadastre-import.
        Probe("JobRunEnvelope", #"""
        {"jobName":"spatial-import","jobRunId":"run1","success":true,
         "startedAt":"2026-09-26T10:00:00.000Z","completedAt":"2026-09-26T10:00:04.000Z",
         "durationMs":4000,"itemsScanned":14,"itemsActioned":14,"itemsSkipped":0,
         "details":{"tenantId":"t","locationId":"l","fileRecordId":"f",
           "format":"shapefile","parcelCount":14,"matched":11,"created":3,
           "flagged":2,"jobRunId":"run1"}}
        """#) { _ = try await APIClient.shared.decode($0, as: JobRunEnvelope.self) },

        // The farm profile, fourteen fields all in `required` — twelve
        // nullable, `grainProduced` neither nullable nor optional, and the
        // lock's `version`.
        Probe("FarmProfile", #"""
        {"producerName":"Иван Петров","egn":"7501011234","eik":"203912345",
         "urn":"1234567","address":"ул. Дунав 3","municipality":"Плевен",
         "settlement":"Плевен","agricultureDirectorateCity":"Плевен",
         "registrationPlace":"Плевен","registrationEkatte":"56722",
         "odbhCity":"Плевен","sizeHa":124.5,"grainProduced":["wheat"],"version":3}
        """#) { _ = try await AdminAPI.decodeFarmProfile(from: $0) },

        // The catalogue, whose `commodity` is the only optional field.
        Probe("InsuranceCatalogue", #"""
        {"engineVersion":1,"currencySymbol":"€","products":[
          {"key":"wheat","kind":"crop","commodity":"wheat","tariffBp":1000,
           "name":"Пшеница","blurb":"Покритие за пшеница."}]}
        """#) { _ = try await APIClient.shared.decode($0, as: InsuranceCatalogue.self) },

        // The three counts that were described to this app before they were on
        // the wire. Probed against the published `required` so the next time
        // they change shape it is this suite that says so, not a blank screen.
        Probe("SpatialImportDetails", #"""
        {"tenantId":"t","locationId":"l","fileRecordId":"f","format":"shapefile",
         "parcelCount":14,"matched":11,"created":3,"flagged":2,"jobRunId":"run1"}
        """#) { _ = try await APIClient.shared.decode($0, as: SpatialImportDetails.self) },

        Probe("SpatialImportAccepted", #"""
        {"jobId":"j","fileRecordId":"f","format":"shapefile","status":"queued"}
        """#) { _ = try await APIClient.shared.decode($0, as: SpatialImportAccepted.self) },

        Probe("ExchangeInquiry", #"""
        {"id":"i","status":"PENDING","message":"здравей",
         "createdAt":"2026-09-01T10:00:00.000Z","contactSharedAt":null}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeInquiry.self) },

        // ── The surfaces documented on 2026-09-26 ──
        //
        // Борса and Тенденции were two of five tabs whose routes were in no
        // schema at all, so their models were "measured, not contracted" —
        // the exact state `CostSlice.variant` was in when one colourless
        // slice could have blanked the calculator. They are checkable now.
        Probe("ExchangeListing", #"""
        {"id":"l","side":"SELL","kind":"CULTURE","status":"ACTIVE",
         "commodity":"wheat","quantityTonnes":"250","pricePerTonne":"51.13",
         "priceCurrency":"EUR","regionCode":"BG-23","regionName":"София",
         "lat":42.7,"lon":23.3,"description":"суха","sellerDisplayName":"Иван",
         "expiresAt":"2026-12-01T00:00:00.000Z","createdAt":"2026-09-01T10:00:00.000Z",
         "isOwn":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeListing.self) },

        Probe("PriceSeries", #"""
        {"source":"ec","region":"BG","stage":"delivered","unit":"t",
         "currency":"EUR","label":"EC BG","lastObservedAt":"2026-09-18",
         "points":[{"date":"2026-09-18","price":229.5,"count":4}]}
        """#) { _ = try await APIClient.shared.decode($0, as: PriceSeries.self) },

        Probe("NewsItem", #"""
        {"id":"n","title":"Заглавие","summary":"Обобщение","url":"https://x.bg/a",
         "source":"agri.bg","category":"MARKET","imageUrl":null,
         "publishedAt":"2026-09-25T06:00:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: NewsItem.self) },

        Probe("Unit", #"""
        {"id":"u","key":"L_PER_DA","name":"литра на декар","symbol":"л/дка",
         "measure":"RATE","createdAt":"2026-01-01T00:00:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: Unit.self) },

        Probe("InputItem", #"""
        {"id":"i","name":"Раундъп","category":"PESTICIDE",
         "defaultUnit":{"id":"u","key":"L","symbol":"л","measure":"VOLUME"},
         "createdByUserId":"user1"}
        """#) { _ = try await APIClient.shared.decode($0, as: InputItem.self) },

        Probe("PricePoint", #"""
        {"date":"2026-09-18","price":229.5,"count":4}
        """#) { _ = try await APIClient.shared.decode($0, as: PricePoint.self) },

        // ── Exchange messaging, agrent-ios#114 ──
        //
        // Every payload complete per the spec's `required`, including the
        // present-and-null keys, and decoded through the route's own
        // function where there is one. `ExchangeMessage` has its own probe
        // because this file mutates top-level keys only: inside
        // `ExchangeThread` it is never touched.
        Probe("ExchangeThreadPage", #"""
        {"threads":[{"id":"t","listingId":"l","listingCommodity":"wheat",
          "listingRegionName":"Pleven","listingQuantityTonnes":"25",
          "sellerDisplayName":null,"role":"seller",
          "lastMessageAt":"2026-09-28T09:15:00.000Z","closed":false,"hasUnread":true}],
         "nextCursor":null}
        """#) { _ = try await ExchangeAPI.decodeThreads(from: $0) },

        Probe("ExchangeThreadSummary", #"""
        {"id":"t","listingId":"l","listingCommodity":"wheat",
         "listingRegionName":"Pleven","listingQuantityTonnes":"25",
         "sellerDisplayName":"Стопанство","role":"inquirer",
         "lastMessageAt":"2026-09-28T09:15:00.000Z","closed":true,"hasUnread":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeThreadSummary.self) },

        Probe("ExchangeThread", #"""
        {"id":"t","listingId":"l","listingCommodity":"wheat","role":"seller",
         "lastMessageAt":"2026-09-28T09:15:00.000Z","closed":false,"blocked":false,
         "unreadCount":1,"olderCursor":"b3BhcXVl",
         "messages":[{"id":"m","senderTenantId":"x","mine":false,"body":"Здравейте",
           "deleted":false,"createdAt":"2026-09-28T09:15:00.000Z"}]}
        """#) { _ = try await ExchangeAPI.decodeThread(from: $0) },

        Probe("ExchangeMessage", #"""
        {"id":"m","senderTenantId":"x","mine":true,"body":"Да",
         "deleted":false,"createdAt":"2026-09-28T09:15:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeMessage.self) },

        Probe("ExchangeThreadOpened", #"""
        {"id":"t","created":true}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeThreadOpened.self) },

        Probe("ExchangeMessageSent", #"""
        {"id":"m","createdAt":"2026-09-28T09:15:00.000Z","reopened":false,"replayed":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeMessageSent.self) },

        Probe("ExchangeThreadRead", #"""
        {"readAt":"2026-09-28T09:15:00.000Z"}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeThreadRead.self) },

        Probe("ExchangeThreadClosed", #"""
        {"closedAt":"2026-09-28T09:15:00.000Z","alreadyClosed":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeThreadClosed.self) },

        Probe("ExchangePartyBlocked", #"""
        {"blocked":true,"alreadyBlocked":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangePartyBlocked.self) },

        Probe("ExchangePartyUnblocked", #"""
        {"blocked":false}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangePartyUnblocked.self) },

        Probe("ExchangeMessageRetracted", #"""
        {"id":"m"}
        """#) { _ = try await APIClient.shared.decode($0, as: ExchangeMessageRetracted.self) },
    ]

    // MARK: - The measurement

    /// Which top-level keys this model cannot decode without.
    ///
    /// A key counts as required if removing it OR nulling it throws. The two
    /// are folded together deliberately: to a farmer looking at a failed
    /// screen the difference does not exist, and a server is free to switch
    /// between them — `undefined` does not survive `JSON.stringify`, which is
    /// exactly how `variant` came to be absent rather than null.
    private func required(_ probe: Probe) async -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(probe.json.utf8)) as? [String: Any] else {
            XCTFail("\(probe.model): the probe payload is not a JSON object")
            return []
        }

        // The complete payload must decode, or nothing below means anything.
        guard (try? await probe.decode(Data(probe.json.utf8))) != nil else {
            XCTFail("\(probe.model): the complete probe payload does not decode")
            return []
        }

        var needed: Set<String> = []
        for key in object.keys {
            var absent = object
            absent.removeValue(forKey: key)

            var nulled = object
            nulled[key] = NSNull()

            for variant in [absent, nulled] {
                guard let data = try? JSONSerialization.data(withJSONObject: variant) else {
                    continue
                }
                if (try? await probe.decode(data)) == nil {
                    needed.insert(key)
                    break
                }
            }
        }
        return needed
    }

    // MARK: - The expectation

    /// What each model cannot decode without, VERIFIED AGAINST THE CONTRACT.
    ///
    /// Every set below was measured by the probe above and then checked, key
    /// by key, against the corresponding schema's `required` list in
    /// `openapi.json` on agri-saas main (2026-09-26). Not one model requires a
    /// key the server does not — which is the first time that has been true,
    /// and the four defects in the header are why it was not.
    ///
    /// ── Reading a failure ──
    ///
    /// A key appearing here that is not expected means a field became
    /// NON-OPTIONAL. That is the defect class: check the schema's `required`
    /// before touching this literal, because making the test green by editing
    /// the expectation is how all four originals would have survived.
    ///
    /// A key disappearing means a field became optional. Usually deliberate
    /// and usually right — update the literal and say why in the commit.
    ///
    /// ── Why a literal and not a fetch ──
    ///
    /// Reading the spec at test time would make this suite fail when the
    /// SERVER changes, on a different repo's timeline, in a repo whose CI is
    /// careful about what it depends on. The comparison against the contract
    /// is a deliberate act by a person with the spec open; this literal is the
    /// record that it happened, and the guard that nothing drifts from it
    /// afterwards without being noticed.
    static let expected: [String: Set<String>] = [
        "CropSeason": ["cropType", "id", "year"],
        "ParcelHistoryOperation": ["doseUnit", "id", "productName", "taskId", "title"],
        "WeedObservation": ["id", "observedAt", "otherWeeds", "weedKeys"],
        "WorkItemSummary": ["createdAt", "id", "status", "title", "type", "updatedAt"],
        "Location": ["id", "name", "status"],
        "CostSlice": ["id", "labelKey", "value"],
        "AgDashboard.JournalItem": ["id", "title", "type"],
        "AgDashboard.LowStockItem": ["id", "name", "quantityOnHand", "unitSymbol"],
        "AgDashboard.TaskItem": ["id", "status", "title"],
        "FarmTaskTrendPoint": ["completed", "created", "date"],
        "BriefingAction": ["action", "priority"],
        "ImportJobStatus": ["state"],

        // ── Checked 2026-09-26 against agri-saas main after #1135/#1137 ──
        //
        // `Parcel` requires two of the ten keys its schema does, which is the
        // safe direction. `absentFromImportAt` is `["string","null"]` AND in
        // `required` — present-and-null — so it is absent from this set on
        // purpose: a non-optional there would fail the whole array from one
        // row, on the screen the map draws from.
        "Parcel": ["id", "name"],

        // Six of the nine `required`. `details` is not among them because it
        // is read with `try?` — two job kinds share the envelope and a
        // cadastre payload must not fail a spatial poll. `startedAt`,
        // `completedAt` and `durationMs` are on the wire and unread.
        "JobRunEnvelope": ["itemsActioned", "itemsScanned", "itemsSkipped",
                           "jobName", "jobRunId", "success"],

        // Four of the nine. `bounds` is untyped AND optional — the one
        // combination that has cost this repo a screen twice — so it is not
        // modelled at all.
        "SpatialImportDetails": ["created", "flagged", "matched", "parcelCount"],

        // All three of its `required`. The PRODUCT's own optional field is
        // `commodity`, which this probe cannot reach — it mutates top-level
        // keys only, and `products` is an array of objects. That limitation is
        // the one the server session and this repo found on the same day from
        // opposite directions.
        "InsuranceCatalogue": ["currencySymbol", "engineVersion", "products"],

        // ONE of thirteen, and that one is the odd field out. Twelve are
        // `["<type>","null"]` — present-and-null — so the model takes them as
        // optionals and refuses none. `grainProduced` is `type: array` with no
        // null and is in `required`, so it is the only key this model cannot
        // do without, and modelling it as an optional would describe a state
        // the server cannot produce.
        //
        // `version` (agri-saas#1184, checked 2026-10-01) is `integer` and in
        // `required`, yet NOT here: the model takes it as `Int?` so a server
        // without the lock still loads the screen, and nil saves unguarded —
        // the route's documented absent-header behaviour. Requiring it would
        // trade a working read for a lock the server did not offer.
        "FarmProfile": ["grainProduced"],
        "SpatialImportAccepted": ["fileRecordId", "format", "jobId", "status"],
        "ExchangeInquiry": ["id"],
        "PricePoint": ["date", "price"],

        // ── Checked 2026-09-26 against the schemas documented that day ──
        //
        // Борса and Тенденции had no schema at all until this week, so
        // every model below was "measured, not contracted" — and measurement
        // only ever sees the values that happened to arrive, which is how
        // `CostSlice.variant` survived a year. Each set is a strict SUBSET of
        // its schema's `required`, i.e. this client tolerates more than the
        // server promises, which is the safe direction:
        //
        //     ExchangeListing  vs ExchangeListing     (spec also requires 10 more)
        //     PriceSeries      vs TrendSeries         (also label, lastObservedAt, stage)
        //     NewsItem         vs NewsItem            (also imageUrl, summary)
        //     Unit             vs Unit                (also createdAt, measure, name)
        //     InputItem        vs CatalogItemListRow AND CatalogItemDetail
        //
        // `InputItem` is checked against BOTH item schemas deliberately: this
        // app decodes it from the list and the detail, which are genuinely
        // different shapes. The detail does not carry `defaultUnit` at all and
        // the list's copy has no `name`, which the model's own header
        // documents from production. `reorderLevel` differs harder still —
        // a decimal STRING on the list and a NUMBER on the detail — and is
        // not modelled here, which is why that cannot bite us.
        "ExchangeListing": ["commodity", "createdAt", "id", "isOwn", "kind", "side", "status"],
        "PriceSeries": ["currency", "points", "region", "source", "unit"],
        "NewsItem": ["category", "id", "publishedAt", "source", "title", "url"],
        "Unit": ["id", "key", "symbol"],
        "InputItem": ["category", "id", "name"],

        // ── Checked 2026-09-30 against agri-saas 11b00118 (agrent-ios#114) ──
        //
        // Every set a strict SUBSET of its schema's `required`. What is left
        // out, and why:
        //
        //   - present-and-null keys (`["string","null"]` AND required):
        //     `nextCursor`, `sellerDisplayName`, `olderCursor`, `body`. Swift
        //     optionals, so absent from these sets on purpose — the
        //     `Parcel.absentFromImportAt` precedent. Copying the spec's lists
        //     word for word would turn this suite red.
        //   - `listingRegionName` and `listingQuantityTonnes`: required and
        //     non-null in the spec, optional here, because an inbox row with
        //     a commodity and a time is still worth showing.
        //   - `unreadCount` and `senderTenantId`: nothing reads them.
        //     `hasUnread` is the unread signal and `mine` decides the side.
        //   - WRITE responses require only what a caller cannot do without;
        //     the 2xx is the success, and a missing flag must not turn a
        //     delivered message into an error a farmer retries.
        "ExchangeThreadPage": ["threads"],
        "ExchangeThreadSummary": ["closed", "hasUnread", "id", "lastMessageAt",
                                  "listingCommodity", "listingId", "role"],
        "ExchangeThread": ["blocked", "closed", "id", "lastMessageAt",
                           "listingCommodity", "listingId", "messages", "role"],
        "ExchangeMessage": ["createdAt", "deleted", "id", "mine"],
        "ExchangeThreadOpened": ["id"],
        "ExchangeMessageSent": ["id"],
        "ExchangeThreadRead": ["readAt"],
        "ExchangeThreadClosed": [],
        "ExchangePartyBlocked": ["blocked"],
        "ExchangePartyUnblocked": ["blocked"],
        "ExchangeMessageRetracted": ["id"],
    ]

    /// THE GUARD. A field going non-optional turns this red and names it.
    func testNoModelRequiresMoreThanTheContractDoes() async throws {
        for probe in Self.probes {
            let needed = await required(probe)
            let expected = try XCTUnwrap(
                Self.expected[probe.model],
                "\(probe.model) has no expectation — add one, from the schema's "
                + "`required` list and not from what the decoder happens to do")

            let extra = needed.subtracting(expected).sorted()
            XCTAssertTrue(extra.isEmpty,
                "\(probe.model) now REFUSES to decode without \(extra). If the server "
                + "does not require these, one row missing one of them fails the whole "
                + "array and the screen with it. Check the schema before editing the "
                + "expectation.")

            let gone = expected.subtracting(needed).sorted()
            XCTAssertTrue(gone.isEmpty,
                "\(probe.model) no longer requires \(gone) — probably right, and "
                + "probably deliberate. Update the expectation and say why.")
        }
    }

    /// Every probe carries an expectation, and every expectation a probe. A
    /// model added to one and not the other is a check that quietly does not
    /// run — the shape this whole file exists to catch, one level up.
    func testTheProbesAndExpectationsCoverTheSameModels() {
        XCTAssertEqual(Set(Self.probes.map(\.model)), Set(Self.expected.keys))
    }

    /// Printed rather than asserted, so the expectations above are seeded from
    /// what the decoders actually do instead of from what I remember them
    /// doing. Left in permanently: when this test goes red, the first thing
    /// anybody wants is the measured set, and re-deriving it by hand is how a
    /// wrong expectation gets committed to make a build green.
    func testReportWhatEveryModelRequires() async {
        var lines: [String] = []
        for probe in Self.probes {
            let needed = await required(probe)
            lines.append("  \(probe.model): \(needed.sorted())")
        }
        print("MEASURED — keys each model cannot decode without:\n"
              + lines.joined(separator: "\n"))
    }
}
