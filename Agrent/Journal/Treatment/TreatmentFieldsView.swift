import SwiftUI

/// «Ново мероприятие», step one: what was done (agrent-ios#293).
///
/// Every field the ДНЕВНИК prints for the kind, all required, and «Напред»
/// only once they are filled. The parts that are not typed say so: the
/// earliest harvest date is computed from the date and the quarantine
/// period, and the treated area comes from the parcels chosen next.
///
/// The product field is the parcel sheet's — typed, matched against the
/// farm's catalogue, with its suggestions — so a product is named the same
/// way wherever it is recorded.
struct TreatmentFieldsView: View {
    @Binding var draft: TreatmentDraft
    let reference: OperationReferenceStore
    let onNext: () -> Void

    private var catalogue: [InputItem]? { reference.items.value }
    private var units: [Unit] { reference.units.value ?? [] }
    private var typed: TypedProduct { draft.typed(in: catalogue) }
    private var problems: [TreatmentDraft.Problem] { draft.problems(catalogue: catalogue) }

    private var suggestions: [InputItem] {
        TypedProduct.suggestions(for: draft.productText, spraying: draft.kind == .spray,
                                 in: catalogue ?? [])
    }

    var body: some View {
        PageForm {
            Section {
                Picker("Вид", selection: $draft.kind) {
                    ForEach(TreatmentDraft.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Дата", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            }

            productSection

            if draft.kind == .spray {
                Section(titled: "Вредител") {
                    TextField("Вредител", text: $draft.pestText,
                              prompt: .fieldPrompt(Self.pestExample), axis: .vertical)
                        .promptRoom(Self.pestExample)
                }
            }

            Section(titled: "Доза") {
                FieldRow("Количество") {
                    TextField("0", text: $draft.doseText, prompt: .fieldPrompt("0"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                MenuPicker("Мерна единица", selection: $draft.doseUnit, value: draft.doseUnit?.symbol ?? "—") {
                    Text("—").tag(Unit?.none)
                    ForEach(units) { Text($0.symbol).tag(Unit?.some($0)) }
                }
            }

            // PRZ's place for it: after the dose, before the period (#363).
            if draft.kind == .spray {
                Section {
                    TextField("Фенофаза/BBCH", text: $draft.phenophaseText,
                              prompt: .fieldPrompt(Self.phenophaseExample))
                        .accessibilityInputLabels(A11y.spokenNames("Фенофаза", "BBCH", "Growth stage"))
                } header: {
                    SectionHeader("Фенофаза/BBCH")
                } footer: {
                    SectionFooter(Self.phenophaseNote)
                }
            }

            if draft.kind == .spray {
                Section {
                    // The unit in the prompt, not the title, as on the parcel
                    // sheet: «Карантинен срок, дни» was cut at the default size.
                    FieldRow("Карантинен срок", spoken: "Карантинен срок в дни") {
                        TextField("дни", text: $draft.quarantineText, prompt: .fieldPrompt("дни"))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    ValueRow("Най-ранна дата за прибиране") {
                        Text(draft.earliestHarvest.map(BgDate.full) ?? "—")
                            .accessibilityLabel(draft.earliestHarvest.map(BgDate.full) ?? "не е изчислена")
                    }
                } header: {
                    SectionHeader("Карантинен срок")
                } footer: {
                    SectionFooter(Self.harvestNote)
                }

                Section {
                    MenuPicker("Техника", selection: $draft.technique, value: draft.technique.label) {
                        ForEach(ApplicationTechnique.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    SectionFooter("Техниката се записва в ДНЕВНИКА така, както е избрана.")
                }
            }

            Section {
                if let problem = problems.first {
                    Text(problem.text)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.areaNote)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .inlineTitle("Ново мероприятие")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Напред", action: onNext)
                    .disabled(!problems.isEmpty)
                    // Why it is dimmed, where the dimmed button is: the
                    // reason itself is the last row of a long form.
                    .accessibilityHint(problems.first?.text ?? "")
                    .accessibilityInputLabels(A11y.Spoken.next)
            }
        }
        .onChange(of: typed) { _, now in draft.prefill(from: now, units: units) }
        .onChange(of: units) { _, now in draft.prefill(from: typed, units: now) }
        .task { await reference.load() }
    }

    @ViewBuilder
    private var productSection: some View {
        Section(titled: draft.kind.inputLabel) {
            TextField("Търговско наименование", text: $draft.productText,
                      prompt: .fieldPrompt("Търговско наименование"))
                .autocorrectionDisabled()

            // The farm's own products the typed text is part of — a tap takes
            // the stored name rather than a near-copy.
            ForEach(suggestions) { item in
                Button(item.name) { draft.productText = item.name }
                    .accessibilityHint("Попълва това наименование")
            }

            switch typed {
            case .existing:
                note("Продуктът е в каталога на стопанството.")
            case .new where draft.kind == .spray:
                note("Нов препарат — ДНЕВНИКЪТ изисква регистрационния му номер. "
                     + "Номерът се въвежда само веднъж и се пази към препарата.")
                FieldRow("Рег. № по ЗЗР", spoken: "Регистрационен номер по ЗЗР") {
                    TextField("Номер", text: $draft.registrationText, prompt: .fieldPrompt("Номер"))
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            case .new:
                note("Нов тор — ще бъде добавен в каталога на стопанството.")
            case .empty, .wrongKind, .sample:
                EmptyView()
            }

            // `.value == nil` is true for a failure as well as a load in
            // progress, so this is matched on the state.
            if case .failed(let message) = reference.items {
                VStack(alignment: .leading, spacing: 6) {
                    note(message)
                    Button("Опитайте отново") { Task { await reference.load() } }
                        .font(.footnote)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let pestExample = "напр. Листни въшки"
    static let phenophaseExample = "напр. BBCH 31 или братене"
    /// Where it goes, as the farmer will see it on the printed sheet
    /// (agri-saas #2089): not in the chemical table, which has no such
    /// column, but in the scouting table's «Фенофаза/BBCH», on a row marked
    /// as derived from the treatment rather than a separate inspection.
    static let phenophaseNote = "По избор. В ДНЕВНИКА се отпечатва в таблицата за обследване, "
        + "на ред, отбелязан като изведен от мероприятието."
    private static let harvestNote =
        "Най-ранната дата за прибиране е датата на третирането плюс карантинния срок."
    private static let areaNote =
        "На следващата стъпка изберете културата и парцелите. Площта се изчислява от тях."
}
