import SwiftUI

/// Риск по парцели — each field's vegetation and moisture, from the
/// satellite.
///
/// ── What this screen is careful about ──
///
/// The numbers are spatial MEANS over a parcel's boundary. The satellite
/// overlay on Локации is per-pixel across a whole location. A farmer
/// comparing one bright patch there against a number here will find them
/// different, and both are right — so the number is labelled as an
/// average rather than left to imply a pixel.
///
/// The acquisition date is shown on every row that has one. A false-colour
/// reading with no date is taken as current, and the satellite composite
/// reaches back past cloud cover without saying so. That mistake already
/// happened once on Тенденции, where a price observed in July sat under a
/// chart that looked like today.
struct FarmRiskView: View {
    /// Read so the readings row can stop being a fixed-width column at the
    /// accessibility sizes — see `reading(_:_:value:index:)`.
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var store = FarmRiskStore()

    /// The enquiry form's target — a parcel when a row opened it, or none
    /// when the action button did and the farmer has yet to choose.
    ///
    /// It replaced a confirmation alert. The alert asked yes-or-no about a
    /// figure nobody had been shown; the form asks for the figure, because
    /// the area a field is INSURED for is not always the area on record and
    /// the lead cannot be revised once it is sent.
    @State private var requesting: RequestTarget?



    var body: some View {
        RoutedStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        locationPicker
                    }
                    .solidBar(hairline: .bottom)
                }
                // THE ACTION BUTTON, and the screen's only way to ask
                // (owner, 2026-10-21, #386): «Застраховай» at the bottom
                // right. The per-row asks are gone. It opens the enquiry form
                // with nothing chosen; the form lists the parcels and says
                // which were asked about already.
                //
                // Hidden rather than disabled when there is nothing to ask
                // about: no parcels, no permission, or every parcel already
                // asked about. A floating button that refuses is a promise
                // the screen cannot keep.
                .actionButton(
                    "Застраховай",
                    systemImage: "checkmark.shield",
                    isEnabled: store.mayAsk && !allParcels.isEmpty
                ) {
                    requesting = RequestTarget(parcel: nil)
                }
                .inlineTitle("Риск по парцели")
                // «Затвори» only when the app menu presented this — see
                // `closeWhenPresentedFromMenu`. As a tab root it had one that did nothing.
                .closeWhenPresentedFromMenu()
                .task {
                    await store.loadWho()
                    if store.locations.value == nil { await store.loadLocations() }
                    if store.parcels.value == nil { await store.loadParcels() }
                    await store.loadLeads()
                    await store.readRisks()
                    // The catalogue, so the ask sheet can price a preview. A
                    // failure here is not surfaced: no catalogue means no
                    // preview, and the sheet says so in its own words rather
                    // than putting an error on a screen about satellite
                    // readings.
                    await store.readCatalogue()
                }
                // A FORM, because there is no undo.
                //
                // An insurance ask is unique per (parcel, tenant) with no
                // DELETE and no withdraw — a 15-minute undo was specified
                // and then dropped. An alert could only ask yes-or-no about
                // an area the farmer had never seen; the form settles the
                // figure BEFORE the single irreversible write, which is the
                // only order that works when nothing can be corrected
                // afterwards.
                .sheet(item: $requesting) { target in
                    InsuranceRequestForm(
                        parcels: (store.parcels.value ?? []).map(\.parcel),
                        alreadyAsked: store.askedParcelIDs,
                        preselected: target.parcel,
                        catalogue: store.catalogue.value
                    ) { parcel, area, quote, shown in
                        Task {
                            await store.ask(parcel.id, area: area, quote: quote,
                                            shownPremiumCents: shown)
                        }
                    }
                }
                // WHEN THE SERVER PRICED IT DIFFERENTLY.
                //
                // Only appears when the two figures disagree — a phone carrying
                // a compiled-in tariff against a newer one server-side. Silence
                // is right when they agree, and the sheet has already closed by
                // the time the response lands, so this is the only place left
                // to say it.
                .alert("Окончателна сума", isPresented: Binding(
                    get: { store.serverQuoteNotice != nil },
                    set: { if !$0 { store.clearServerQuoteNotice() } }
                )) {
                    Button("Добре", role: .cancel) { store.clearServerQuoteNotice() }
                } message: {
                    Text(store.serverQuoteNotice ?? "")
                }
                .alert("Запитването не беше изпратено", isPresented: Binding(
                    get: { store.askFailure != nil },
                    set: { if !$0 { store.clearAskFailure() } }
                )) {
                    Button("Добре", role: .cancel) { store.clearAskFailure() }
                } message: {
                    Text(store.askFailure ?? "")
                }
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationPicker: some View {
        if let locations = store.locations.value, locations.count > 1 {
            Picker("Блок", selection: Binding(
                get: { store.selected?.id ?? "" },
                set: { id in
                    if let match = locations.first(where: { $0.id == id }) {
                        Task { await store.select(match) }
                    }
                }
            )) {
                ForEach(locations) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// EVERY parcel, including ones already asked about.
    ///
    /// This filtered out parcels with a lead, because the server refused a
    /// second ask with 409 and letting someone type an area only to eat
    /// that refusal was the failure `GET /insurance/leads` existed to
    /// prevent. The constraint is gone, and that endpoint is now
    /// informational — it says what has been asked, it does not say what
    /// may be.
    private var allParcels: [Parcel] {
        (store.parcels.value ?? []).map(\.parcel)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.parcels {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            // BOTH. Reloading the parcels alone left every row on
            // «Изчисляване…» for ever: `readRisks` is reachable only from
            // this view's `.task`, which has already run, and from
            // `select`. The screen looked like it was working.
            ErrorState(message: message) {
                await store.loadParcels()
                await store.readRisks()
            }

        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState(
                "Няма парцели",
                icon: "map",
                message: "Този блок още няма въведени парцели."
            )

        case .loaded(let rows, _):
            List(rows) { row in
                parcelRow(row)
                    .pageRow()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            .listStyle(.plain)
            .pageBackground()
        }
    }

    // MARK: - One parcel

    /// THREE STOPS PER PARCEL: the reading, the archive, the insurance ask.
    ///
    /// It was about twelve. Every other list in this app groups its row —
    /// `TaskRow`, `JournalRow`, `MemberRow` all build one spoken sentence
    /// from the values — and this one, the densest row in the app, never
    /// did. A VoiceOver user swiped through the name, the area, the crop,
    /// «Зеленина», its chip, «NDVI 0,62 ср.», «Влага», its chip, «NDMI 0,31
    /// ср.» and the acquisition line before reaching the next parcel. Seven
    /// parcels is eighty-odd swipes to read a screen a sighted farmer takes
    /// in at a glance.
    ///
    /// `children: .ignore` on the WHOLE row would have been the obvious
    /// thing and the wrong one — it swallows controls, which is exactly the
    /// defect the ЕГН row on Админ was fixed for. So the grouping stops
    /// short of «История» and the ask's status, which stay their own stops.
    ///
    /// Spoken from the VALUES rather than `.combine`, for the reason
    /// `JournalRow` records: the acquisition line contains a `·`, and
    /// VoiceOver reads it as "middle dot".
    private func parcelRow(_ row: RiskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            parcelReading(row)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))

            RiskHistoryButton(parcel: row.parcel)

            askStatus(row)
        }
    }

    private func parcelReading(_ row: RiskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and area on one line: both short, each pinned to its
            // own edge, neither able to grow into the other.
            //
            // EXCEPT AT THE ACCESSIBILITY SIZES, where "both short" stops
            // being true — «Нива до шосето» at accessibility5 is most of the
            // screen on its own, and the area it is pinned away from is a
            // number the farmer is reading the row FOR. The `Spacer` holds
            // them apart until there is nothing left to hold apart, and then
            // the area wraps to «2,4 / ха» in the last few points.
            let nameAndArea = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))

            nameAndArea {
                Text(row.parcel.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let area = row.risk?.areaHa ?? row.parcel.areaHa {
                    Text(Area(hectares: area).text)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            if let crop = CommodityName.freeText(row.risk?.cropType ?? row.parcel.cropType) {
                Text(crop).font(.footnote).foregroundStyle(Palette.secondaryText)
            }

            if let risk = row.risk {
                ParcelRiskReadings(risk: risk, freshness: row.freshness)
            } else if let failure = row.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The parcel is listed before its reading arrives, so the
                // list is complete from the first frame and fills in.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Изчисляване…").font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    /// What the grouped reading says, built from the values.
    private func spoken(_ row: RiskRow) -> String {
        var parts: [String?] = [
            row.parcel.name,
            (row.risk?.areaHa ?? row.parcel.areaHa).map { Area(hectares: $0).text },
            CommodityName.freeText(row.risk?.cropType ?? row.parcel.cropType),
        ]

        if let risk = row.risk {
            parts += ParcelRiskReadings.spoken(risk, row.freshness)
        } else if let failure = row.failure {
            parts.append(failure)
        } else {
            // The row exists before its reading does. Saying so beats a
            // parcel that announces a name and an area and then stops.
            parts.append("изчислява се")
        }

        return A11y.sentence(parts)
    }

    /// Where an ask about this parcel stands: being sent, or asked already.
    /// Status only (#386). The owner removed the per-row ask, leaving the
    /// screen's «Застраховай», so this is what still shows that an ask sent
    /// from the form was sent. Hidden from a MECHANISATOR, for whom
    /// `/insurance` is outside the operator allowlist (`store.mayAsk`).
    @ViewBuilder
    private func askStatus(_ row: RiskRow) -> some View {
        if store.mayAsk {
            if store.asking.contains(row.parcel.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Изпраща се…").font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            } else if store.askedParcelIDs.contains(row.parcel.id) {
                Label("Заявено запитване", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    /// WHEN THE SATELLITE LOOKED, and how long ago.
    ///
    /// Computed from two server timestamps — see `Staleness`. A reading
    /// with no date reads as today's, and the composite reaches back past
    /// cloud cover without saying so.
    /// The acquisition line as DATA, so the row's spoken label and the row
    /// itself cannot say different things.
    ///
    /// Two joins over one source: the screen puts a `·` between the clauses,
    /// the spoken label a comma. That is the whole reason this is not simply
    /// `.combine`d off the rendered text — VoiceOver reads `·` as "middle
    /// dot", which `JournalRow` found first.
    struct Acquisition {
        var clauses: [String]
        var isStale: Bool

        var shown: String { clauses.joined(separator: " · ") }
        var spoken: String { clauses.joined(separator: ", ").lowercased() }
    }

    /// A CACHED READING MAY NOT SAY «ДНЕС», OR COUNT DAYS.
    ///
    /// `staleDays` is `generatedAt − acquiredDate` and both are frozen
    /// inside the payload, so an analysis fetched on Monday whose
    /// acquisition was Monday still computes 0 on Thursday. Served from the
    /// cache it would print «Заснето днес» over a three-day-old image — and
    /// the parcel list above it can be perfectly fresh, so the stale banner
    /// says nothing.
    ///
    /// The absolute date is the part that stays true whatever the payload's
    /// age, so a stale reading shows that alone. The relative clause is
    /// dropped rather than guessed at: the cache knows when IT was written,
    /// not when the satellite passed.
    static func acquisition(_ risk: ParcelRisk, _ freshness: Freshness?) -> Acquisition? {
        guard let date = risk.acquired else { return nil }
        let days = risk.staleDays ?? 0
        let isCached = { if case .stale = freshness { return true } else { return false } }()

        if isCached {
            return Acquisition(clauses: ["Заснето на \(BgDate.dayMonth(date))"], isStale: true)
        }
        if days <= 0 {
            return Acquisition(clauses: ["Заснето днес"], isStale: false)
        }
        return Acquisition(
            clauses: [
                "Заснето на \(BgDate.dayMonth(date))",
                "преди \(Plural.bg(days, "ден", "дни"))",
            ],
            isStale: days > Staleness.satellitePass
        )
    }

}

/// THE ARCHIVE, as its own control on a risk row, never the whole row.
///
/// This row is where the archive belongs: it is the one list of parcels every
/// role can open. Shown for EVERY role: `GET /history` is a READ under
/// `/api/t/{slug}/agro/…`, one of the prefixes the operator lockdown lets
/// through (`CurrentUser.isOperator`).
///
/// ── Its own view, so it pushes onto THIS stack (#386) ──
///
/// It was a method on `FarmRiskView` calling `FarmRiskView`'s
/// `@Environment(\.pushRoute)`. `RoutedStack` sets `pushRoute` on the
/// `NavigationStack` it builds, which is INSIDE `FarmRiskView`, so the view
/// that builds the stack reads the default, which does nothing. That's
/// exactly what the owner saw (2026-10-21). A view placed inside the stack
/// reads the stack's own.
///
/// 44pt, because a footnote and a caption chevron unframed are an 18pt
/// target, in a field, in gloves. `ParcelMapView` uses the same frame.
///
/// Spoken with the parcel's name in it. "История" alone is clear on screen,
/// inside a named row, but not to someone swiping element by element.
private struct RiskHistoryButton: View {
    let parcel: Parcel
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        Button {
            pushRoute(.parcelHistory(parcelID: parcel.id, parcelName: parcel.name))
        } label: {
            HStack(spacing: 4) {
                Text("История")
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .accessibilityLabel("История на парцел \(parcel.name)")
        .accessibilityHint("Отваря записаните реколти, дейности и плевели за този парцел")
    }
}
