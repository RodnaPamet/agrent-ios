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
    let onSubmit: (Parcel, Area?) -> Void

    @State private var selectedID: String?
    @State private var areaText: String = ""
    @Environment(\.dismiss) private var dismiss

    /// Opened from a row: that parcel, fixed. Opened from the action
    /// button: whichever parcels can still be asked about.
    init(parcels: [Parcel], alreadyAsked: Set<String>,
         preselected: Parcel? = nil,
         onSubmit: @escaping (Parcel, Area?) -> Void) {
        self.parcels = parcels
        self.alreadyAsked = alreadyAsked
        self.onSubmit = onSubmit
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
                            Text("дка").foregroundStyle(.secondary)
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Изпрати") {
                        if let selected { onSubmit(selected, area) }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
        }
    }

    private func parcelLine(_ parcel: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(parcel.name).font(.subheadline.weight(.medium))
            if let crop = CommodityName.freeText(parcel.cropType) {
                Text(crop).font(.footnote).foregroundStyle(.secondary)
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
