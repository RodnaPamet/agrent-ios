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

        Probe("TrendDataPoint", #"""
        {"date":"2026-09-24","evidenceOverdue":0,"evidenceDueSoon7d":0,
         "evidenceCurrent":2,"tasksOpen":1,"tasksOverdue":0,"assetsTotal":3,
         "assetsActive":3,"assetsHighCriticality":0,"assetsRetired":0}
        """#) { _ = try await APIClient.shared.decode($0, as: TrendDataPoint.self) },

        Probe("FarmTaskTrendPoint", #"""
        {"date":"2026-09-25","created":3,"completed":1}
        """#) { _ = try await APIClient.shared.decode($0, as: FarmTaskTrendPoint.self) },

        Probe("BriefingAction", #"""
        {"field":"Долен блок","action":"Провери влагата","priority":"high"}
        """#) { _ = try await APIClient.shared.decode($0, as: BriefingAction.self) },

        Probe("ImportJobStatus", #"""
        {"jobId":"job","state":"active","failedReason":null}
        """#) { _ = try await APIClient.shared.decode($0, as: ImportJobStatus.self) },

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
        "TrendDataPoint": [
            "assetsActive", "assetsHighCriticality", "assetsRetired", "assetsTotal",
            "date", "evidenceCurrent", "evidenceDueSoon7d", "evidenceOverdue",
            "tasksOpen", "tasksOverdue",
        ],
        "FarmTaskTrendPoint": ["completed", "created", "date"],
        "BriefingAction": ["action", "priority"],
        "ImportJobStatus": ["state"],
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
