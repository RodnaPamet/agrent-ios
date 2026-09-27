import SwiftUI

/// The insurance enquiry, as a form rather than a confirmation.
///
/// ── Why this replaced an alert ──
///
/// The ask used to be a one-tap confirmation over a figure the farmer never
/// saw and could not change. The area a field is INSURED for is not always
/// the area on record — a parcel can be part-sown, part-leased, or simply
/// wrong in the register — and the operator receiving the enquiry has to
/// quote against the right number. So the number is asked for.
///
/// ── The area travels in `message` ──
///
/// The server has no area column: `InsuranceLead` holds parcelId,
/// locationId, message, riskJson and status, so accepting one is a schema
/// change and a migration rather than a validation edit. The figure goes
/// into the free-text `message` that becomes the operator's email, next to
/// the registered area when the two differ — and the difference is the
/// signal, so a bare number in a new column would have lost it.
///
/// ── One submit, no revision ──
///
/// A lead is unique per (parcel, tenant) with no DELETE, no PATCH and no
/// withdraw, so a typed area cannot be corrected once sent. That is why
/// this is a form and not a confirmation: the figure is settled BEFORE the
/// single irreversible write, rather than after it.
struct InsuranceRequestForm: View {
    let parcels: [Parcel]
    let alreadyAsked: Set<String>
    /// The fetched products and tariffs, or nil when they have never been
    /// loaded on this device. Nil is not an error — it is "no preview", which
    /// is a complete state: a message-only ask still works.
    let catalogue: InsuranceCatalogue?

    /// The premium is handed back so the caller can compare it with the
    /// server's. It is what was ON SCREEN, which is the only figure worth
    /// comparing — see `FarmRiskStore.correctionNotice`.
    let onSubmit: (Parcel, Area?, CreateLead.Quote?, Int?) -> Void

    @State private var selectedID: String?
    @State private var areaText: String = ""

    /// THE QUOTE IS OPTIONAL, and starts off.
    ///
    /// A message-only ask is what this form did before the calculator existed
    /// and is still a complete, useful enquiry — an operator reads the field,
    /// its size and what the satellite said, and quotes back. So the figures
    /// are something a farmer opts INTO rather than four more fields standing
    /// between them and asking a question.
    @State private var wantsQuote = false
    @State private var productKey: String?
    @State private var sumInsuredText: String = ""
    @State private var instalments: Int = 1
    @Environment(\.dismiss) private var dismiss

    /// Opened from a row: that parcel, fixed. Opened from the action
    /// button: whichever parcels can still be asked about.
    init(parcels: [Parcel], alreadyAsked: Set<String>,
         preselected: Parcel? = nil,
         catalogue: InsuranceCatalogue? = nil,
         onSubmit: @escaping (Parcel, Area?, CreateLead.Quote?, Int?) -> Void) {
        self.parcels = parcels
        self.alreadyAsked = alreadyAsked
        self.catalogue = catalogue
        self.onSubmit = onSubmit
        _productKey = State(initialValue: catalogue?.products.first?.key)
        // PREFILL FROM WHATEVER IS SELECTED, not from `preselected`.
        //
        // Opened from the action button there is no preselection, so the
        // form fell back to the first askable parcel for the picker and
        // left the area blank beside it — a named field with an empty area
        // and its registered size printed directly underneath, which reads
        // as the app having lost the number.
        // Opens on a parcel with no lead when one exists, since a first
        // ask is the likelier intent — but any parcel can be chosen.
        let opening = preselected
            ?? parcels.first { !alreadyAsked.contains($0.id) }
            ?? parcels.first
        _selectedID = State(initialValue: opening?.id)
        _areaText = State(initialValue: Self.areaText(for: opening))
    }

    /// EVERY parcel. `alreadyAsked` marks, it no longer filters.
    ///
    /// This excluded parcels with a lead, because the server refused a
    /// second ask with 409 and letting someone pick one, type an area and
    /// submit was the failure `GET /insurance/leads` existed to prevent.
    /// The constraint is gone (agri-saas f98e39d2) and that endpoint is
    /// informational now — it says what HAS been asked, not what MAY be.
    ///
    /// Filtering here would make the correction the change was made for
    /// unreachable from the phone.
    private var available: [Parcel] { parcels }

    private var selected: Parcel? {
        available.first { $0.id == selectedID }
    }

    /// HECTARES, converted from what was typed in decares.
    ///
    /// The field shows decares because that is what a Bulgarian farm works
    /// in; the wire is hectares and stays hectares. One conversion, here,
    /// at the edge.
    ///
    /// An UNTOUCHED field submits the parcel's exact recorded area rather
    /// than the round trip of its own prefill. `Num.text` shows at most two
    /// decimals, so a parcel of 32,4567 ха prefills as «324,57 дка» and
    /// parsing that back gives 32,457 ха — a silent 0,0007 ха edit by
    /// somebody who typed nothing. Sending the original is the only honest
    /// reading of "they left it alone".
    private var area: Area? {
        guard let typed = Area.parse(decares: areaText) else { return nil }
        if let selected, areaText == Self.areaText(for: selected) {
            return selected.areaHa.map(Area.init(hectares:))
        }
        return typed
    }

    /// Decares, as typed. The AREA parser, so «12,345» is twelve and a bit.
    private var areaDecares: Double? {
        InsurancePremium.areaDecares(areaText)
    }

    /// The MONEY parser, so «100 000» is one hundred thousand.
    private var sumInsuredCents: Int? {
        InsurancePremium.moneyCents(sumInsuredText)
    }

    private var product: InsuranceCatalogue.Product? {
        productKey.flatMap { catalogue?.product(key: $0) }
    }

    /// THE PREVIEW IS REFUSED RATHER THAN SHOWN STALE, in two cases.
    ///
    /// No catalogue: nothing has ever been fetched on this device, so there is
    /// no tariff to price with. Cached counts as fetched — calculating offline
    /// is fine, and only SENDING needs a connection.
    ///
    /// A NEWER ENGINE: the server's `engineVersion` has moved past the one
    /// `InsurancePremium`'s arithmetic was written for, so what this app
    /// computes is no longer what gets stored and emailed. The server session's
    /// own words: "that is the signal to stop previewing or to update."
    ///
    /// A visible refusal beats a silent wrong number — the same reasoning that
    /// shows the server's figure over ours on disagreement. Without this, a
    /// phone left on an old build previews confidently and wrongly forever.
    private var previewRefusal: String? {
        guard let catalogue else {
            return "Изчислението не е налично офлайн, преди да е заредено веднъж. "
                 + "Може да изпратите запитване без изчисление."
        }
        guard catalogue.matchesLocalArithmetic else {
            return "Изчислението в приложението вече не съвпада с това на "
                 + "застрахователя. Изпратете запитване без изчисление — "
                 + "офертата се изчислява от тях."
        }
        return nil
    }

    private var estimate: InsurancePremium.Quote? {
        guard wantsQuote, previewRefusal == nil,
              let product, let sumInsuredCents
        else { return nil }
        return InsurancePremium.quote(sumInsuredCents: sumInsuredCents,
                                      tariffBp: product.tariffBp,
                                      instalments: instalments)
    }

    /// Which field could not be read. Named, because "invalid" in front of two
    /// number fields tells a farmer to check both.
    private var unreadableInputNote: String {
        if areaDecares == nil, !areaText.isEmpty {
            return "Площта не се разчита. Използвайте «12,5» за дванадесет и половина декара."
        }
        if sumInsuredCents == nil, !sumInsuredText.isEmpty {
            return "Сумата не се разчита. Използвайте «100 000» или «100,50»."
        }
        return "Въведете площ и застрахователна сума, за да видите прогнозата."
    }

    /// What crosses the wire, or nil for a message-only ask.
    ///
    /// `areaScope` is sent as `custom` only when the farmer changed the area
    /// away from the register — otherwise the scope IS the parcel and the
    /// server's default says so. `crop-at-location` is not produced here: it
    /// requires `coveredParcelCount` and a crop-wide selection this form has no
    /// concept of, and sending the scope without the count is a 400.
    private var wireQuote: CreateLead.Quote? {
        guard wantsQuote, let product, let sumInsuredCents,
              let areaDecares, areaDecares > 0
        else { return nil }

        let recorded = selected?.areaHa.map(Area.init(hectares:))
        let edited = recorded.map { area?.differs(from: $0) == true } ?? false

        return CreateLead.Quote(
            productKey: product.key,
            areaDca: areaDecares,
            sumInsuredCents: sumInsuredCents,
            instalments: instalments,
            areaScope: edited ? CreateLead.Quote.scopeCustom : nil
        )
    }

    /// WHY SEND CAN BE BLOCKED, or nil when it cannot.
    ///
    /// Only blocks on something the farmer can fix. It deliberately does NOT
    /// block on being offline: this app has no reachability monitor, and one
    /// reporting "connected" says nothing about the server being reachable —
    /// so a disabled button would be wrong in both directions. Sending fails
    /// with «Запитването не беше изпратено» instead, which is honest, and
    /// nothing is ever queued: this POST does not go through the outbox.
    private var sendBlockedReason: String? {
        guard selected != nil else { return "Изберете парцел." }
        guard wantsQuote else { return nil }
        // A REFUSED PREVIEW DOES NOT BLOCK SENDING. The quote simply is not
        // attached, and the ask goes as a message — which is a complete
        // enquiry and what this form did before the calculator existed.
        if previewRefusal != nil { return nil }
        if product == nil { return "Изберете покритие." }
        if sumInsuredText.isEmpty { return "Въведете застрахователна сума." }
        return wireQuote == nil ? unreadableInputNote : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if available.isEmpty {
                    RefusalNote(
                        text: "Тази локация няма парцели.",
                        icon: "map")
                } else {
                    Section {
                        if available.count == 1, let only = available.first {
                            parcelLine(only)
                        } else {
                            // A navigation-link picker, not a menu: parcel
                            // names are long and the collapsed value of a
                            // menu picker is the one place they get cut.
                            Picker("Парцел", selection: $selectedID) {
                                ForEach(available) { parcel in
                                    // The marker travels with the name, so
                                    // a farmer sees which fields they have
                                    // already asked about while choosing,
                                    // rather than after.
                                    Text(alreadyAsked.contains(parcel.id)
                                         ? "\(parcel.name) ✓"
                                         : parcel.name)
                                        .tag(Optional(parcel.id))
                                }
                            }
                            .pickerStyle(.navigationLink)
                            .onChange(of: selectedID) { _, _ in
                                areaText = Self.areaText(for: selected)
                            }
                        }
                    }

                    Section {
                        HStack {
                            TextField("0", text: $areaText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("дка").foregroundStyle(Palette.secondaryText)
                        }
                        .accessibilityLabel("Площ за застраховане в декари")
                    } header: {
                        Text("Площ за застраховане")
                    } footer: {
                        if let recorded = selected?.areaHa.map(Area.init(hectares:)),
                           let area, area.differs(from: recorded) {
                            // Said out loud rather than silently corrected.
                            // A deliberate difference is the reason this
                            // field exists; a typo looks identical, and only
                            // the farmer can tell them apart.
                            Text("По регистър: \(recorded.text).")
                                .foregroundStyle(Palette.warning)
                        } else if let recorded = selected?.areaHa {
                            Text("По регистър: \(Area(hectares: recorded).text).")
                        }
                    }

                    Section {
                        Toggle("Изчисли премия", isOn: $wantsQuote)
                    } footer: {
                        Text("Може да изпратите запитване и без изчисление — "
                             + "тогава оферта дава застрахователят.")
                    }

                    if wantsQuote, let refusal = previewRefusal {
                        Section {
                            Label(refusal, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if wantsQuote, let catalogue {
                        Section {
                            Picker("Покритие", selection: $productKey) {
                                Section("Култури") {
                                    ForEach(catalogue.products.filter(\.isCrop)) {
                                        Text($0.name).tag(Optional($0.key))
                                    }
                                }
                                Section("Рискове") {
                                    ForEach(catalogue.products.filter { !$0.isCrop }) {
                                        Text($0.name).tag(Optional($0.key))
                                    }
                                }
                            }
                            .pickerStyle(.navigationLink)

                            HStack {
                                TextField("0", text: $sumInsuredText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                // The tenant's own symbol, so the app does not
                                // guess at a currency it was never told.
                                Text(catalogue.currencySymbol)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            .accessibilityLabel("Застрахователна сума в евро")

                            Picker("Вноски", selection: $instalments) {
                                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Брой вноски")
                        } header: {
                            Text("Изчисление")
                        } footer: {
                            // «100 000» is one hundred thousand and «12,345»
                            // decares is twelve and a bit: the two fields read
                            // the same characters differently, which is the
                            // server's rule and has to be said rather than
                            // discovered. The area field is above and already
                            // labelled in decares.
                            Text("Сумата се въвежда в евро: «100 000» е сто хиляди. "
                                 + "«100,50» е сто евро и петдесет цента.")
                        }

                        if let estimate {
                            Section {
                                LabeledContent("Прогнозна премия") {
                                    Text(InsurancePremium.eur(estimate.premiumCents))
                                        .fontWeight(.semibold)
                                }
                                if let perDca = areaDecares.flatMap(estimate.perDecareCents) {
                                    LabeledContent("На декар") {
                                        Text(InsurancePremium.eur(perDca))
                                    }
                                }
                                if estimate.instalmentsCents.count > 1 {
                                    LabeledContent("Вноски") {
                                        Text(estimate.instalmentsCents
                                            .map(InsurancePremium.eur)
                                            .joined(separator: " + "))
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            } footer: {
                                // AN ESTIMATE, NOT A PRICE, and the distinction
                                // is load-bearing rather than modest. The
                                // request carries no price; the server
                                // recomputes and its figure is what gets stored
                                // and emailed. This phone also carries a
                                // compiled-in tariff, so a rate change server
                                // side makes this number stale with nothing
                                // here able to know it.
                                Text("Прогноза. Окончателната сума се изчислява "
                                     + "от застрахователя при изпращане.")
                            }
                        } else if !sumInsuredText.isEmpty || !areaText.isEmpty {
                            Section {
                                Label(unreadableInputNote,
                                      systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Section {
                        // The warning is now narrower and truer. A lead
                        // still cannot be withdrawn — there is no DELETE
                        // and no PATCH — but it is no longer one per
                        // parcel, and saying so would misdescribe the
                        // server and discourage the correction this form
                        // exists to allow.
                        Label(
                            selected.map { alreadyAsked.contains($0.id) } == true
                                ? "За този парцел вече има запитване. Това ще изпрати "
                                + "ново, което не може да бъде оттеглено."
                                : "Запитването не може да бъде оттеглено.",
                            systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                    }
                }
            }
            // «Запитване», not «Запитване за оферта».
            //
            // This bar carries a text button on each side, and the title
            // gets what is left. The longer name truncated to «Запитване
            // за о...» — real width pressure rather than the Bulgarian
            // measurement defect, which `BulgarianLayout` already fixes.
            // The sheet's own content says what the enquiry is for.
            .inlineTitle("Запитване")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Изпрати") {
                        if let selected {
                            onSubmit(selected, area, wireQuote, estimate?.premiumCents)
                        }
                        dismiss()
                    }
                    // Blocked only on what a farmer can fix — NOT on being
                    // offline. See `sendBlockedReason`.
                    .disabled(sendBlockedReason != nil)
                    .accessibilityInputLabels(A11y.Spoken.send)
                }
            }
        }
    }

    private func parcelLine(_ parcel: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(parcel.name).font(.subheadline.weight(.medium))
            if let crop = CommodityName.freeText(parcel.cropType) {
                Text(crop).font(.footnote).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    // MARK: - The number

    /// DECARES, which is what the field shows.
    private static func areaText(for parcel: Parcel?) -> String {
        parcel?.areaHa.map { Area(hectares: $0).number } ?? ""
    }
}

/// What the enquiry form was opened about.
///
/// A parcel when a row opened it, nil when the action button did and the
/// farmer has yet to choose. Identifiable so `sheet(item:)` carries it,
/// with a fixed id for the nil case so the button presents exactly once.
struct RequestTarget: Identifiable {
    let parcel: Parcel?
    var id: String { parcel?.id ?? "any" }
}
