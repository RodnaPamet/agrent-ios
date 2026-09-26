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

    /// The parcel whose archive is being pushed, or nil.
    ///
    /// A PROGRAMMATIC PUSH RATHER THAN A `NavigationLink`, and the reason is
    /// the row it lives in: `parcelRow` already contains a Button — the
    /// insurance ask — and a `NavigationLink` inside a List row makes the
    /// WHOLE row tappable. The two controls would then overlap, and which one
    /// a tap reached would depend on where in the row it landed. The insurance
    /// ask writes something that cannot be withdrawn, so an ambiguous tap
    /// there is not a cosmetic problem.
    ///
    /// A Button that sets this, plus one `navigationDestination`, keeps each
    /// control's hit area its own.
    @State private var history: Parcel?


    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
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
                // Declared ONCE for the whole list rather than per row: a
                // destination inside a row is scoped to that row's lifetime,
                // and rows here are rebuilt every time a reading arrives.
                .navigationDestination(item: $history) { parcel in
                    ParcelHistoryView(parcelID: parcel.id, parcelName: parcel.name)
                }
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
    /// short of the two buttons, and they stay their own stops.
    ///
    /// Spoken from the VALUES rather than `.combine`, for the reason
    /// `JournalRow` records: the acquisition line contains a `·`, and
    /// VoiceOver reads it as "middle dot".
    private func parcelRow(_ row: RiskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            parcelReading(row)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))

            historyControl(row)

            askControl(row)
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
                readings(risk, row.freshness)
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
            parts.append(spokenReading("зеленина", risk.vegetation, risk.ndvi, "NDVI"))
            parts.append(spokenReading("влага", risk.moisture, risk.ndmi, "NDMI"))
            parts.append(risk.absenceReason)
            parts.append(Self.acquisition(risk, row.freshness)?.spoken
                ?? "датата на заснемане е неизвестна")
        } else if let failure = row.failure {
            parts.append(failure)
        } else {
            // The row exists before its reading does. Saying so beats a
            // parcel that announces a name and an area and then stops.
            parts.append("изчислява се")
        }

        return A11y.sentence(parts)
    }

    /// «зеленина добро, NDVI 0,62 средно» — the chip's MEANING rather than
    /// its rendered fragment, and «ср.» spelled out, which is an
    /// abbreviation on screen and a word in the ear.
    private func spokenReading(
        _ title: String, _ level: RiskLevel, _ value: Double?, _ index: String
    ) -> String {
        var text = "\(title) \(level.label.lowercased())"
        if let value { text += ", \(index) \(Num.text(value)) средно" }
        return text
    }

    /// THE ARCHIVE, as its own control — never the whole row.
    ///
    /// This row is where the archive belongs: it is the one list of parcels
    /// every role can open, and the map tap that looks like the obvious home
    /// for it opens `ParcelOperationSheet` — a form to RECORD an operation,
    /// gated on `mayCreateOperations`, which is false for MECHANISATOR, READER
    /// and AUDITOR. The archive would have been invisible to the operator who
    /// sprayed the field.
    ///
    /// Shown for EVERY role, and not gated on anything. `GET /history` is a
    /// READ under `/api/t/{slug}/agro/…`, and `agro` is one of the five
    /// prefixes the server's operator lockdown lets through — see
    /// `CurrentUser.isOperator`. So this is not the `/insurance` division that
    /// hides `askControl` from a MECHANISATOR, and it is not a write, so
    /// `mayCreateOperations` has nothing to say about it either.
    ///
    /// The label is spoken with the parcel's name in it. "История" alone is
    /// unambiguous on screen, where it sits inside a named row, and useless to
    /// someone swiping between elements one at a time.
    private func historyControl(_ row: RiskRow) -> some View {
        Button {
            history = row.parcel
        } label: {
            HStack(spacing: 4) {
                Text("История")
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .font(.footnote.weight(.medium))
            // 44pt, WHICH IS THE POINT — `contentShape` alone was not.
            //
            // `contentShape(Rectangle())` on an unframed HStack makes the gap
            // between the text and the chevron hit-testable instead of just
            // the glyphs. It does not ENLARGE anything. That left a footnote
            // plus a caption chevron, roughly 18pt tall, sitting 8pt above
            // `askControl` — which sends an insurance enquiry that has no
            // DELETE, no PATCH and no withdraw.
            //
            // Two sub-44pt targets 8pt apart, one of them irreversible, is
            // the same mis-tap this control was carefully shaped to avoid by
            // not being a NavigationLink wrapping a Button — the ambiguity
            // arriving by a different route. In a field, on a phone, in
            // gloves. `ParcelMapView` already uses this frame for the same
            // reason.
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .accessibilityLabel("История на парцел \(row.parcel.name)")
        .accessibilityHint("Отваря записаните реколти, дейности и плевели за този парцел")
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
                    Text("Изпраща се…").font(.footnote).foregroundStyle(Palette.secondaryText)
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
                            .foregroundStyle(Palette.secondaryText)
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
                    // 44pt, on the IRREVERSIBLE one.
                    //
                    // A `.plain` button around a `.footnote` Label with no
                    // frame has the glyphs themselves as its hit area — about
                    // 18pt tall. This is the control that sends an insurance
                    // enquiry with no DELETE, no PATCH and no withdraw.
                    //
                    // «История ›» eight points above it was given a 44pt frame
                    // yesterday, for the stated reason that two small targets
                    // beside an irreversible one is a mis-tap waiting to
                    // happen. I enlarged the reversible control and left the
                    // irreversible one at glyph size, which is the wrong way
                    // round and was invisible until an audit measured both.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
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
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            acquisition(risk, freshness)
        }
    }

    private func reading(
        _ title: String, _ level: RiskLevel, value: Double?, index: String
    ) -> some View {
        // A COLUMN WHILE IT FITS, STACKED WHEN IT CANNOT.
        //
        // `Text(title).frame(width: 72)` boxed «Зеленина» at a hard 72pt. At
        // `.footnote` that is comfortable by default and ruinous at the five
        // accessibility sizes, where the word wants roughly 290pt: with no
        // `fixedSize` the column breaks it into two- and three-letter
        // fragments and the tail is simply cut. On the one screen whose job is
        // telling a farmer WHICH reading is bad — and the chip beside it says
        // only the level, while the trailing text is an index code.
        //
        // The 72 is worth keeping below that threshold: it aligns «Зеленина»
        // and «Влага» so the two chips form a column you can compare down.
        // Above it the alignment is the thing that has to go, because there
        // are only two readings and losing the column costs less than losing
        // the words. `NewsView` already switches axis on the same threshold.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: typeSize.isAccessibilitySize ? nil : 72,
                       alignment: .leading)

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
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
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

    @ViewBuilder
    private func acquisition(_ risk: ParcelRisk, _ freshness: Freshness?) -> some View {
        if let line = Self.acquisition(risk, freshness) {
            Label(line.shown, systemImage: "camera.badge.clock")
                .font(.caption)
                // NEVER `.secondary`, which is what this was. The parcel map
                // says it in its own comment: this line is the caveat on
                // every number above it, and it must not read as a footnote.
                .foregroundStyle(line.isStale ? Palette.warning : Color.primary)
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
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
