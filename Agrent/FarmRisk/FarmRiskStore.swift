import Foundation
import Observation

/// A parcel and its reading, once one arrives.
struct RiskRow: Identifiable, Equatable, Sendable {
    let parcel: Parcel
    var risk: ParcelRisk?
    var failure: String?

    /// THE READING'S OWN FRESHNESS, not the parcel list's.
    ///
    /// `staleDays` is `generatedAt − acquiredDate`, and BOTH are frozen
    /// inside the payload — so an analysis fetched on Monday whose
    /// acquisition was Monday still computes 0 on Thursday and says
    /// «Заснето днес» over a three-day-old image. The parcel list's
    /// freshness cannot correct it: the list and the readings are separate
    /// requests with separate caches, and the list is routinely fresh while
    /// the readings are not.
    ///
    /// This is the Тенденции July-price failure, which is the thing this
    /// screen was built to avoid making again.
    var freshness: Freshness?

    var id: String { parcel.id }

    /// Worst first, unread last, then by name so the order is stable
    /// between loads rather than shuffling as readings arrive.
    /// Worst first, unread last, then by name, then by ID.
    ///
    /// The ID is the third component because `sorted` is not guaranteed
    /// stable and two parcels can share a name — the owner's farm numbers
    /// several fields alike. Without it the list can reorder between two
    /// renders of identical data.
    var sortKey: (Int, String, String) {
        ((risk?.overall ?? .unknown).severityOrder, parcel.name, parcel.id)
    }
}

@Observable
@MainActor
final class FarmRiskStore {
    private(set) var locations: LoadState<[Location]> = .loading
    private(set) var parcels: LoadState<[RiskRow]> = .loading
    private(set) var isReadingRisks = false

    /// Bumped whenever the selection changes. `readRisks` abandons a loop
    /// whose generation no longer matches, instead of the old flag, which
    /// only ever asked "is A still running?" and answered "yes, so B must
    /// not start" — stranding B's rows on «Изчисляване…» for ever while
    /// A's publishes were dropped one by one against ids that no longer
    /// existed. One request per parcel at up to fifteen seconds each makes
    /// that window the whole load, not a race you have to be unlucky to
    /// hit.
    private var generation = 0

    var selected: Location?

    /// Parcels already asked about. Read from the server, never remembered
    /// locally — the web page tracked this in component state, it died on
    /// unmount, and an operator got a refusal for retrying something they
    /// had no way to see they had done.
    private(set) var askedParcelIDs: Set<String> = []

    /// Nil until `/api/auth/me` resolves. The ask is OFFERED meanwhile —
    /// `mayAsk` fails open, the same decision `mayCreateOperations`
    /// records: hiding a control from somebody who could have used it is
    /// worse than showing one the server might refuse, because a refusal
    /// is a sentence they can read and an absence is a feature they
    /// conclude does not exist.
    private(set) var me: CurrentUser?

    /// May this person ask an insurer?
    ///
    /// `/insurance` is outside the operator API allowlist, so a
    /// MECHANISATOR gets 403 `operator_scope` on both leads calls while
    /// the readings work fine. That division looks deliberate — knowing a
    /// field is stressed is field work, contacting an insurer is not — so
    /// the control is HIDDEN for them rather than shown and refused.
    var mayAsk: Bool { !(me?.isOperator ?? false) }

    private(set) var asking: Set<String> = []
    private(set) var askFailure: String?

    func loadWho() async {
        me = await CurrentUserStore.shared.load()
    }

    /// Which parcels are already spent. Read from the server every time
    /// the screen opens; never cached in view state.
    func loadLeads() async {
        guard mayAsk else { return }
        do {
            let data = try await APIClient.shared.data(for: FarmRiskAPI.leadsPath)
            askedParcelIDs = Set(try await FarmRiskAPI.decodeLeads(from: data).parcelIds)
        } catch {
            // A failure here must NOT be read as "nothing was asked" — that
            // would re-enable a button whose write the server then refuses.
            // Leaving the set as it was is the honest degradation: the
            // control stays in whatever state was last known true.
            Log.api.error("could not read insurance leads")
        }
    }

    /// Fire the ask. NEVER retried automatically.
    ///
    /// One parcel can be asked about exactly once, ever. There is no undo
    /// — it was specified and then dropped — so an automatic retry after a
    /// lost response is the one thing that could turn a farmer's single
    /// deliberate tap into something they did not choose. A 409 on replay
    /// is success, so a manual retry is safe; an automatic one is still
    /// not offered.
    /// `area` is what the farmer typed, which may differ from the area on
    /// record — it is the figure they want insured. It travels inside
    /// `message`, because the server has no area column and adding one is a
    /// migration; carried this way it reaches the operator's email today
    /// rather than after a release on both sides.
    ///
    /// Typed as `Area` rather than a bare `Double` so the unit cannot be
    /// lost between the form and the sentence an operator reads.
    /// WHAT THE SERVER PRICED IT AT, when that differs from the estimate the
    /// farmer was shown.
    ///
    /// Nil when there was no quote, or when the two agree — silence is the
    /// right output for "the number you saw is the number that was sent". It is
    /// only set when the screen owes an explanation, which is the case where a
    /// phone carrying a stale tariff previewed one figure and the operator
    /// received another.
    private(set) var serverQuoteNotice: String?

    func clearServerQuoteNotice() { serverQuoteNotice = nil }

    /// The products and their tariffs. Cached, so a preview still works with
    /// no signal — calculating offline is fine, only SENDING needs a
    /// connection.
    private(set) var catalogue: LoadState<InsuranceCatalogue> = .loading

    func readCatalogue() async {
        await CachedResource.loadShowingCacheFirst(
            InsuranceCatalogueAPI.path,
            decode: InsuranceCatalogueAPI.decode,
            publish: { [weak self] state in
                self?.catalogue = state
                // Logged, not shown. A farmer can do nothing about it and it
                // does not make the preview wrong — the TARIFF is still the
                // server's. It makes two screens disagree about what a crop is
                // called, which is a thing for whoever reads the logs.
                for row in state.value?.labelsDisagreeingWithCommodityName ?? [] {
                    Log.api.error("""
                        insurance catalogue names \(row.key, privacy: .public) as                         "\(row.fetched, privacy: .public)" where CommodityName says                         "\(row.ours, privacy: .public)" — change the server's                         messages/ entry rather than hardcoding either side
                        """)
                }
            }
        )
    }

    /// THE IDEMPOTENCY KEY, and the one rule that makes it worth having.
    ///
    /// Minted at the first send and KEPT across retries while the inputs are
    /// unchanged, so a retry after a timeout replays the original lead rather
    /// than writing a second row and sending a second operator email. A NEW key
    /// is minted the moment any input changes, because then it is not a retry —
    /// it is the corrected ask, and replaying the old one would tell a farmer
    /// their correction went out when the original did.
    ///
    /// CLEARED ON SUCCESS, which is the half that is easy to get wrong. After a
    /// success there is no retry; a farmer asking again with the same figures is
    /// asking again, and the server expects several asks per parcel now. Keeping
    /// the key would silently collapse that into the first lead.
    private var pendingKey: (fingerprint: String, key: String)?

    private func idempotencyKey(for fingerprint: String) -> String {
        if let pendingKey, pendingKey.fingerprint == fingerprint {
            return pendingKey.key
        }
        let minted = UUID().uuidString
        pendingKey = (fingerprint, minted)
        return minted
    }

    func ask(_ parcelID: String, area: Area? = nil,
             quote: CreateLead.Quote? = nil,
             shownPremiumCents: Int? = nil) async {
        guard mayAsk, !asking.contains(parcelID) else { return }
        let row = parcels.value?.first { $0.id == parcelID }
        asking.insert(parcelID)
        askFailure = nil
        defer { asking.remove(parcelID) }
        do {
            let created = try await FarmRiskAPI.createLead(
                CreateLead(
                    parcelId: parcelID,
                    message: Self.leadMessage(row, area: area),
                    locationId: selected?.id,
                    risk: row?.risk.map {
                        CreateLead.RiskSnapshot(
                            overall: $0.overall.rawValue, ndvi: $0.ndvi, ndmi: $0.ndmi)
                    },
                    quote: quote
                ),
                idempotencyKey: idempotencyKey(
                    for: Self.fingerprint(parcelID: parcelID, quote: quote))
            )
            pendingKey = nil
            askedParcelIDs.insert(parcelID)
            serverQuoteNotice = Self.correctionNotice(
                shownPremiumCents: shownPremiumCents, got: created.quote)
        } catch {
            // NO SUCCESS-ON-REPLAY BRANCH ANY MORE. A 409 used to mean "this
            // parcel was already asked about" and was recorded as success; the
            // route has no conflict path since the unique index was dropped,
            // so every error here is an error. See `FarmRiskAPI.createLead`.
            recordAskFailure(error)
        }
    }

    func clearAskFailure() { askFailure = nil }

    /// The inputs that decide whether a send is a RETRY or a new ask.
    ///
    /// The parcel is in it as well as the four quote values: re-asking about a
    /// different parcel is obviously not a retry, and leaving it out would have
    /// replayed the first parcel's lead.
    static func fingerprint(parcelID: String, quote: CreateLead.Quote?) -> String {
        guard let quote else { return "\(parcelID)|message-only" }
        return [parcelID, quote.productKey, String(quote.areaDca),
                String(quote.sumInsuredCents), String(quote.instalments),
                quote.areaScope ?? CreateLead.Quote.scopeParcel].joined(separator: "|")
    }

    /// Nil when there is nothing to explain.
    ///
    /// TAKES THE FIGURE THAT WAS ON SCREEN rather than recomputing it. The
    /// question is "did the farmer read a different number from the one that
    /// was sent", and only the form knows what it displayed — it computed the
    /// estimate from the catalogue's tariff for the chosen product. Recomputing
    /// here would be a second description of one thing, and it could quietly
    /// use a different tariff than the one the preview used.
    ///
    /// Compares only the PREMIUM. The instalment split follows from it, so two
    /// equal premiums cannot disagree on the parts unless the server changed
    /// its splitting rule — and if it did, the premium is still the number a
    /// farmer is owed an explanation about.
    static func correctionNotice(shownPremiumCents: Int?,
                                 got: CreatedLead.ServerQuote?) -> String? {
        guard let shown = shownPremiumCents, let got,
              shown != got.premiumCents
        else { return nil }

        return "Изчислението на сървъра е \(InsurancePremium.eur(got.premiumCents)), а не "
             + "\(InsurancePremium.eur(shown)). Запитването е изпратено със "
             + "сумата на сървъра."
    }

    /// THE failure handler, called by `ask`'s `catch` and by its test — one
    /// method, not a copy.
    ///
    /// `ask` cannot be exercised in a unit test: it POSTs, and the standing
    /// rule here is never to fire that POST at the live tenant. Extracting the
    /// branch means a test can at least reach the real code rather than a
    /// restatement of it. What stays unasserted is that `ask` calls this, which
    /// is one line and read rather than proved — said out loud because "the
    /// test covers the handler" and "the test covers the behaviour" are
    /// different claims and this repo has confused them before.
    ///
    /// It marks nothing as asked, deliberately. A failure recorded as an ask
    /// would show a farmer a parcel as spent when no operator was emailed.
    func recordAskFailure(_ error: Error) {
        askFailure = UserMessage.text(for: error)
    }

    /// What the operator reads in the email this becomes.
    ///
    /// Written for a person, in Bulgarian, and it names the area the FARMER
    /// gave rather than the one on record when the two differ — that
    /// difference is the point of asking them.
    static func leadMessage(_ row: RiskRow?, area: Area?) -> String {
        let name = row?.parcel.name ?? "парцел"
        var parts = ["Запитване за застрахователна оферта за парцел «\(name)»."]

        if let area {
            parts.append("Площ за застраховане: \(area.text).")
            if let recorded = row?.parcel.areaHa.map(Area.init(hectares:)),
               area.differs(from: recorded) {
                parts.append("По регистър: \(recorded.text).")
            }
        } else if let recorded = row?.parcel.areaHa {
            parts.append("Площ по регистър: \(Area(hectares: recorded).text).")
        }

        if let crop = CommodityName.freeText(row?.parcel.cropType) {
            parts.append("Култура: \(crop).")
        }
        if let risk = row?.risk, risk.overall.isReading {
            parts.append("Сателитна оценка: \(risk.overall.label).")
            if let date = risk.acquired {
                parts.append("Заснето на \(BgDate.dayMonth(date)).")
            }
        }
        // The server caps this at 2000 characters and rejects a longer one,
        // which on a parcel with a very long name is reachable.
        return String(parts.joined(separator: " ").prefix(2000))
    }

    func loadLocations() async {
        await CachedResource.loadShowingCacheFirst(LocationsAPI.listPath) { data in
            try await LocationsAPI.decodeList(from: data)
        } publish: { [weak self] in self?.locations = $0 }
        if selected == nil { selected = locations.value?.first }
        // `loadParcels` returns without touching `parcels` when there is no
        // selection, and `parcels` starts `.loading` — so a locations
        // failure, or a tenant with no locations at all, left a spinner on
        // a blank screen with no message and no retry. `content` switches
        // on `parcels` alone, so a failure sitting in `locations` was never
        // rendered anywhere.
        if selected == nil {
            switch locations {
            case .failed(let message): parcels = .failed(message)
            case .loaded: parcels = .loaded([], .fresh)
            case .loading: break
            }
        }
    }

    func loadParcels() async {
        guard let location = selected else { return }
        if parcels.value == nil { parcels = .loading }
        await CachedResource.loadShowingCacheFirst(
            LocationsAPI.parcelsPath(location.id)
        ) { data in
            try await LocationsAPI.decodeParcels(from: data)
        } publish: { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading:
                self.parcels = .loading
            case .failed(let message):
                self.parcels = .failed(message)
            case .loaded(let response, let freshness):
                // Every parcel appears immediately with no reading, so the
                // list is complete from the first frame and fills in. A
                // farmer sees which fields exist before they see how they
                // are doing, which is the right order — the parcels are
                // the thing they recognise.
                self.parcels = .loaded(
                    response.parcels.map { RiskRow(parcel: $0) }, freshness)
            }
        }
    }

    /// One request per parcel, SEQUENTIALLY, publishing each as it lands.
    ///
    /// Not concurrent: on a weak connection parallel requests compete for
    /// the same scrap of bandwidth and all time out — the same reasoning
    /// as `OfflinePrefetch`. Sequential means the first parcels read
    /// quickly even when the last never does, and the list visibly fills
    /// rather than sitting empty until all of them are in.
    func readRisks() async {
        guard let rows = parcels.value else { return }
        generation += 1
        let mine = generation
        isReadingRisks = true
        defer { if generation == mine { isReadingRisks = false } }

        for row in rows {
            guard generation == mine else { return }
            let path = FarmRiskAPI.analysisPath(row.parcel.id)
            await CachedResource.loadShowingCacheFirst(path) { data in
                try await FarmRiskAPI.decodeAnalysis(from: data)
            } publish: { [weak self] state in
                guard let self, self.generation == mine,
                      case .loaded(var current, let freshness) = self.parcels,
                      let index = current.firstIndex(where: { $0.id == row.parcel.id })
                else { return }
                switch state {
                case .loaded(let risk, let readingFreshness):
                    current[index].risk = risk
                    current[index].failure = nil
                    current[index].freshness = readingFreshness
                case .failed(let message):
                    // Keep the parcel; lose only its reading. A field that
                    // vanishes because its analysis failed is worse than a
                    // field with no reading.
                    current[index].failure = message
                case .loading:
                    return
                }
                // NOT SORTED HERE. Every row starts unread, which is
                // severity 3 and therefore bottom, so re-sorting inside
                // this closure walked each row up the list as its reading
                // landed — under a comment claiming the order was stable
                // between loads. A farmer reads a moving list, and every
                // row of it carries the irreversible ask button.
                self.parcels = .loaded(current, freshness)
            }
        }

        guard generation == mine, case .loaded(let done, let freshness) = parcels else { return }
        parcels = .loaded(done.sorted { $0.sortKey < $1.sortKey }, freshness)
    }

    func select(_ location: Location) async {
        guard location.id != selected?.id else { return }
        selected = location
        generation += 1
        parcels = .loading
        await loadParcels()
        await readRisks()
    }
}
