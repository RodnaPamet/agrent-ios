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
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let age = store.parcels.freshness?.ageDescription {
                            StaleBanner(age: age)
                        }
                        locationPicker
                    }
                    .background(.bar)
                }
                // THE ACTION BUTTON, bottom-leading, as asked for — and
                // the same control other screens will grow for their own
                // primary action. Here it opens the enquiry form with
                // nothing chosen, so a farmer who wants a quote does not
                // have to find the field first.
                //
                // Hidden rather than disabled when there is nothing to ask
                // about: no parcels, no permission, or every parcel already
                // asked about. A floating button that refuses is a promise
                // the screen cannot keep.
                .actionButton(
                    "Запитване за оферта",
                    systemImage: "envelope",
                    isEnabled: store.mayAsk && !allParcels.isEmpty
                ) {
                    requesting = RequestTarget(parcel: nil)
                }
                .inlineTitle("Риск по парцели")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                    }
                }
                .task {
                    await store.loadWho()
                    if store.locations.value == nil { await store.loadLocations() }
                    if store.parcels.value == nil { await store.loadParcels() }
                    await store.loadLeads()
                    await store.readRisks()
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
                        preselected: target.parcel
                    ) { parcel, area in
                        Task { await store.ask(parcel.id, area: area) }
                    }
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
            Picker("Локация", selection: Binding(
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
                message: "Тази локация още няма въведени парцели."
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

    private func parcelRow(_ row: RiskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and area on one line: both short, each pinned to its
            // own edge, neither able to grow into the other.
            HStack(alignment: .firstTextBaseline) {
                Text(row.parcel.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let area = row.risk?.areaHa ?? row.parcel.areaHa {
                    Text(Area(hectares: area).text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let crop = CommodityName.freeText(row.risk?.cropType ?? row.parcel.cropType) {
                Text(crop).font(.footnote).foregroundStyle(.secondary)
            }

            if let risk = row.risk {
                readings(risk, row.freshness)
            } else if let failure = row.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The parcel is listed before its reading arrives, so the
                // list is complete from the first frame and fills in.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Изчисляване…").font(.footnote).foregroundStyle(.secondary)
                }
            }

            askControl(row)
        }
    }

    /// Ask, already asked, or nothing at all.
    ///
    /// Hidden entirely for a MECHANISATOR: `/insurance` is outside the
    /// operator API allowlist, so both leads calls 403 for them while the
    /// readings work. Hidden rather than shown-and-refused, consistent
    /// with how the tab filter treats the same division.
    @ViewBuilder
    private func askControl(_ row: RiskRow) -> some View {
        if store.mayAsk {
            if store.asking.contains(row.parcel.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Изпраща се…").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                let asked = store.askedParcelIDs.contains(row.parcel.id)
                VStack(alignment: .leading, spacing: 4) {
                    // A NOTE BESIDE THE BUTTON, NOT INSTEAD OF IT.
                    //
                    // This used to replace the control entirely, which was
                    // right against a server that answered a second ask
                    // with 409. The constraint is gone (agri-saas
                    // f98e39d2): several asks per parcel, no 409, and the
                    // operator mail deduped on the lead id so a repeat
                    // actually sends rather than vanishing.
                    //
                    // The change exists so a farmer can CORRECT an area
                    // they got wrong. Refusing to reopen the form would
                    // make the correction unreachable from the phone,
                    // which is the one thing dropping the constraint was
                    // for. State still read from the server, never
                    // remembered locally.
                    if asked {
                        Label("Заявено запитване", systemImage: "checkmark.seal")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        requesting = RequestTarget(parcel: row.parcel)
                    } label: {
                        Label(asked ? "Запитай отново" : "Запитай за оферта",
                              systemImage: "envelope")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHint(asked
                        ? "Изпраща ново запитване за този парцел, например с поправена площ"
                        : "Изпраща запитване за застрахователна оферта")
                }
            }
        }
    }

    @ViewBuilder
    private func readings(_ risk: ParcelRisk, _ freshness: Freshness?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two chips, stacked rather than side by side: at accessibility
            // sizes two labelled chips on one line reflow independently and
            // fight, which is the failure JournalDetailView documents.
            reading("Зеленина", risk.vegetation, value: risk.ndvi, index: "NDVI")
            reading("Влага", risk.moisture, value: risk.ndmi, index: "NDMI")

            if let reason = risk.absenceReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            acquisition(risk, freshness)
        }
    }

    private func reading(
        _ title: String, _ level: RiskLevel, value: Double?, index: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            CategoryChip(
                text: level.label,
                foreground: level.colors.foreground,
                background: level.colors.background
            )

            if let value {
                // Labelled as an average, deliberately. The map overlay is
                // per-pixel over the whole location; this is one number
                // over this parcel's boundary. A farmer comparing a bright
                // patch there against this will find them different, and
                // both are correct.
                Text("\(index) \(Num.text(value)) ср.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// WHEN THE SATELLITE LOOKED, and how long ago.
    ///
    /// Computed from two server timestamps — see `Staleness`. A reading
    /// with no date reads as today's, and the composite reaches back past
    /// cloud cover without saying so.
    @ViewBuilder
    private func acquisition(_ risk: ParcelRisk, _ freshness: Freshness?) -> some View {
        if let date = risk.acquired {
            let days = risk.staleDays ?? 0
            // A CACHED READING MAY NOT SAY «ДНЕС», OR COUNT DAYS.
            //
            // `staleDays` is `generatedAt − acquiredDate` and both are
            // frozen inside the payload, so an analysis fetched on Monday
            // whose acquisition was Monday still computes 0 on Thursday.
            // Served from the cache it would print «Заснето днес» over a
            // three-day-old image — and the parcel list above it can be
            // perfectly fresh, so the stale banner says nothing.
            //
            // The absolute date is the part that stays true whatever the
            // payload's age, so a stale reading shows that alone. The
            // relative clause is dropped rather than guessed at: the cache
            // knows when IT was written, not when the satellite passed.
            let isCached = { if case .stale = freshness { return true } else { return false } }()
            Label(
                isCached
                    ? "Заснето на \(BgDate.dayMonth(date))"
                    : days <= 0
                        ? "Заснето днес"
                        : "Заснето на \(BgDate.dayMonth(date)) · преди \(Plural.bg(days, "ден", "дни"))",
                systemImage: "camera.badge.clock"
            )
            .font(.caption)
            // NEVER `.secondary`, which is what this was. The parcel map
            // says it in its own comment: this line is the caveat on every
            // number above it, and it must not read as a footnote.
            .foregroundStyle(
                isCached || days > Staleness.satellitePass ? Color.orange : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // THE `else` THE PARCEL MAP ALREADY HAD.
            //
            // Without it the whole line vanished and the row showed two
            // coloured chips and two index numbers with no date and no
            // caveat — an undated reading wearing the clothes of a current
            // one. `acquiredDate` is optional on the wire, and the parcel
            // map records for the SAME satellite data that the server may
            // omit it; `BgDate.parseISODay` also returns nil for a full
            // instant, which is the other shape this codebase has met.
            Label("Датата на заснемане е неизвестна.", systemImage: "camera.badge.clock")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
