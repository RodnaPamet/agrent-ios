import SwiftUI

/// Add costs to the farm's books: one crop's rates per decare, or the
/// year's overheads, each as one sheet that lands whole or not at all.
///
/// ── This form does NOT retry, and that is still the whole design ──
///
/// `POST /grain/costs` DOES honour `Idempotency-Key` (chain traced in
/// agri-saas source — see `CostsAPI.create`), and since 2026-09-25 this
/// form sends one. What the key buys is that a REPLAY of the same figures
/// cannot become a second row; what it does not buy is a replay. There is
/// none, by the owner's choice, so a duplicate here would still be a
/// duplicated financial record that silently changes net worth, and
/// nothing upstream would catch it.
///
/// Everything below therefore stands unchanged:
///
///   - No automatic retry, no queue, no pull-to-refresh on a failed save.
///   - The button disables the instant it is pressed and does not come
///     back while the request is in flight, so a second tap cannot exist.
///   - A TIMEOUT is reported as unknown rather than as failure. After one
///     the app genuinely does not know whether the row was written, and
///     "не бе записан" invites the operator to enter it again — the single
///     action that makes it worse. Re-typing it into a fresh sheet is a
///     fresh nonce, so the key would NOT dedupe it; the dedupe covers a
///     replay of one attempt, not a human doing the work twice.
struct NewCostView: View {
    /// The crops the calculator reports with land, for «Култура».
    let crops: [CropChoice]
    let onSaved: () -> Void

    init(crops: [CropChoice], onSaved: @escaping () -> Void) {
        self.crops = crops
        self.onSaved = onSaved
        _commodity = State(initialValue: crops.first?.commodity)
    }

    @Environment(\.dismiss) private var dismiss

    /// ── THE IDEMPOTENCY NONCE: one per sheet presentation ──
    ///
    /// Half of the key. The other half is a hash of the draft's content —
    /// `CostIdempotencyKey` holds the reasoning for both, and it is worth
    /// reading before touching either.
    ///
    /// NEVER REASSIGNED. `@State` with an initialiser evaluates it once per
    /// view identity, so this is minted when the sheet appears and is stable
    /// for as long as it is on screen, however many times `body` runs. It
    /// would be a `let` if property wrappers allowed one.
    ///
    /// The two things it must not become:
    ///
    ///   - Re-minted on edit (an `.onChange`): edit-and-revert then produces
    ///     a THIRD value, so the figures that may already have landed are no
    ///     longer deduped against. The content hash handles edits; this does
    ///     not.
    ///   - Shared or global: two sheets with identical content — 200 L of
    ///     diesel bought twice in a day — must mint different keys, or the
    ///     second legitimate cost is deduped away and never written.
    @State private var nonce = UUID().uuidString

    /// «Култура» or «Общи», chosen first (owner, 2026-10-09, #245). «Общи»
    /// is the owner's word for the farm's overheads, renamed the same day
    /// from «Режийни» — the accounting term, which read as jargon.
    @State private var scope: Scope = .crop

    enum Scope: Hashable {
        /// One crop's costs, each a rate per decare over the land the crop
        /// stands on (agri-saas #1583, #1606, #1611).
        case crop
        /// The year's overheads, each spread over the whole farm.
        case overhead
    }

    /// The «Общи» sheet and its prefill sources.
    @State private var overhead = OverheadSheet()
    @State private var machinery: MachineryDepreciation?
    @State private var overheadPrefilled = false
    @State private var currencyEdited = false

    /// The «Култура» sheet: the crop chosen and its rows. A sheet typed for
    /// one crop is kept while another is looked at, so choosing a different
    /// crop by mistake loses nothing.
    @State private var commodity: String?
    @State private var cropSheet = CropSheet()
    @State private var otherCropSheets: [String: CropSheet] = [:]
    @State private var cropsPrefilled: Set<String> = []
    /// Crops the server answered `UNKNOWN_COMMODITY` for: said beside the
    /// crop, since its save would be refused for the same reason.
    @State private var unrecognisedCrops: Set<String> = []

    /// EUR: Bulgaria's currency since 1 January 2026 (owner, 2026-10-10).
    /// Typed over for a cost in another currency.
    @State private var currency = "EUR"
    @State private var incurredOn = Date()

    @State private var saving = false
    @State private var failure: Failure?

    enum Failure: Equatable {
        /// Nothing was written: the server answered and said no, or the
        /// request never left the phone. Trying again is safe.
        case notSaved(String)
        /// No answer arrived. The row may or may not exist, and only the
        /// books can say which.
        case unknown(String)

        /// What a failed save says about the books, for both sides of the
        /// form alike (#265).
        init(_ error: Error) {
            let message = UserMessage.text(for: error)
            if let url = error as? URLError, !WriteOutcome.neverSent(url) {
                // The ambiguous one: the request may have reached the server
                // and been written before the answer was lost.
                self = .unknown(message)
            } else {
                // The server answered, and whatever it said, it said it; or
                // the connection was never made (`WriteOutcome`). Either way
                // the row does not exist.
                self = .notSaved(message)
            }
        }

        var message: String {
            switch self {
            case .notSaved(let message), .unknown(let message): message
            }
        }
    }

    private var canSave: Bool {
        guard !saving else { return false }
        switch scope {
        case .crop:
            guard let crop = chosenCrop else { return false }
            // `problems` holds `.nothingEntered` for an empty sheet.
            return cropSheet.problems(areaDca: crop.areaDca).isEmpty && !answerLost
        case .overhead:
            return overhead.problems.isEmpty && !answerLost
        }
    }

    private var chosenCrop: CropChoice? {
        crops.first { $0.commodity == commodity }
    }

    /// The last save's answer was lost: what was sent may be in the books.
    /// The sheet is then not sent again from here (the owner's rule for a
    /// cost, 2026-09-25: look at the list first), and the choice of side and
    /// crop is fixed so the text saying so stays in front of the operator.
    private var answerLost: Bool {
        if case .unknown? = failure { true } else { false }
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    Picker("Вид разход", selection: $scope) {
                        Text("Култура").tag(Scope.crop)
                        Text("Общи").tag(Scope.overhead)
                    }
                    .pickerStyle(.segmented)
                    .disabled(saving || answerLost)
                } footer: {
                    SectionFooter {
                        Text(scope == .crop
                             ? "Разходите на една култура, всеки на декар, по площта ѝ в стопанството."
                             : "Годишни суми. Всяка се разпределя по площ върху цялото стопанство — "
                               + "земята без култура запазва своя дял.")
                    }
                }

                // At the top, under the choice it fixes: a lost answer dims
                // the whole sheet, and the reason belongs where the operator
                // is looking, not under six sections.
                if let failure {
                    Section { failureView(failure) }
                }

                switch scope {
                case .crop: cropFields
                case .overhead:
                    // Fixed while the sheet is in flight, too: a figure typed
                    // then is not in what was sent, and would close unsaved.
                    OverheadFields(sheet: $overhead, locked: saving || answerLost, machinery: machinery)
                    commonFields
                    if let problem = overheadProblemText {
                        Section { Text(problem).font(.footnote).foregroundStyle(Palette.secondaryText) }
                    }
                }
            }
            .inlineTitle("Нов разход")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запази") {
                            Task { await saveSheet() }
                        }
                        .disabled(!canSave)
                        .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task(id: scope) { if scope == .overhead { await prefillOverheads() } }
            .task(id: commodity) { await prefillCrop() }
            .onChange(of: commodity) { old, new in
                if let old { otherCropSheets[old] = cropSheet }
                cropSheet = new.flatMap { otherCropSheets[$0] } ?? CropSheet()
                failure = nil
            }
            .onChange(of: currency) { currencyEdited = true }
            // A refusal belongs to the side that was sent; a lost answer
            // cannot get here, because it fixes the side.
            .onChange(of: scope) { failure = nil }
            // Said, not only shown: «Запази» is in the toolbar, far from
            // where the answer is drawn.
            .onChange(of: failure) { _, failure in
                if let failure { AccessibilityNotification.Announcement(spoken(failure)).post() }
            }
        }
    }

    /// The crop, its rows per decare, and the sheet's currency and date.
    @ViewBuilder
    private var cropFields: some View {
        if let crop = chosenCrop {
            Section {
                // `MenuPicker`: the system menu picker cuts a Bulgarian
                // value short in the row (#160). The slug is the selection
                // only; every name shown is `CropChoice.name`, which is
                // `CommodityName.canonical`.
                MenuPicker("Култура", selection: $commodity, value: crop.name) {
                    ForEach(crops) { Text($0.name).tag(Optional($0.commodity)) }
                }
                .disabled(saving || answerLost)
                if unrecognisedCrops.contains(crop.commodity) {
                    Text("Сървърът не разпознава „\(crop.name)“ като култура — "
                         + "разход на декар не може да се запише за нея.")
                        .font(.footnote)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CropFields(sheet: $cropSheet, crop: crop, currency: currency, locked: saving || answerLost)
            commonFields
            if let problem = cropProblemText(crop) {
                Section { Text(problem).font(.footnote).foregroundStyle(Palette.secondaryText) }
            }
        } else {
            // A rate per decare needs decares. A farm whose calculator shows
            // no crop on its land has nothing to multiply one by; its yearly
            // costs still go in «Общи».
            Section {
                Text("Няма култура с площ")
                    .font(.headline)
                Text("Разходите на декар се въвеждат за култура, която калкулаторът отчита на "
                     + "площите на стопанството. Годишните разходи се въвеждат в „Общи“.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sheet's currency and date: one each, for every line.
    @ViewBuilder
    private var commonFields: some View {
        Section {
            TextField("Валута", text: $currency, prompt: .fieldPrompt("Валута"))
                .textInputAutocapitalization(.characters)
            DatePicker("Дата", selection: $incurredOn, displayedComponents: .date)
                .tint(Palette.DatePill.tint)
        }
        .disabled(saving || answerLost)
    }

    private var overheadProblemText: String? {
        switch overhead.problems.first {
        case .nothingEntered?, nil: nil
        case .unreadable(let category)?: "\(category.label): сумата не е разчетена."
        case .notPositive(let category)?: "\(category.label): сумата трябва да е по-голяма от нула."
        case .tooLarge(let category)?: "\(category.label): сумата е прекалено голяма."
        case .peopleIncomplete?: "Заплати: въведете и броя хора, и годишната заплата на човек — или изберете „Общо“."
        }
    }

    @ViewBuilder
    private func failureView(_ failure: Failure) -> some View {
        switch failure {
        case .notSaved(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(Palette.error)
                Text("Нито една от сумите НЕ е записана. Можете да опитате отново.")
                    .font(.footnote).foregroundStyle(Palette.secondaryText)
            }
        case .unknown(let message):
            // The honest answer, and it is deliberately not a retry button.
            //
            // The key would make a button SAFE — a replay of this draft with
            // this nonce cannot write a second row. The owner chose the key
            // without the button anyway, on 2026-09-25: after a lost response
            // the app still does not know whether the row exists, and the
            // useful action is to LOOK at the list, which the text below
            // says. A button that quietly succeeds by replaying would teach
            // an operator to press it, and the next screen to grow one may
            // not be a route that dedupes.
            VStack(alignment: .leading, spacing: 6) {
                Label("Неясен резултат", systemImage: "questionmark.circle")
                    .foregroundStyle(Palette.error)
                Text(message).font(.footnote).foregroundStyle(Palette.secondaryText)
                Text("""
                    Връзката прекъсна, преди сървърът да отговори. Сумите \
                    може да са записани, а може и да не са — всички или нито \
                    една. Проверете списъка с разходи, преди да ги въведете \
                    отново — повторното въвеждане ги записва втори път.
                    """)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    /// The answer, and what it means for the books, in one announcement.
    private func spoken(_ failure: Failure) -> String {
        let outcome = switch failure {
        case .notSaved: "Нито една от сумите НЕ е записана."
        case .unknown: "Сумите може да са записани, а може и да не са. Проверете списъка с разходи."
        }
        return "\(failure.message) \(outcome)"
    }

    private func cropProblemText(_ crop: CropChoice) -> String? {
        switch cropSheet.problems(areaDca: crop.areaDca).first {
        case .nothingEntered?, nil: nil
        case .unreadable(let category)?: "\(category.label): сумата на декар не е разчетена."
        case .notPositive(let category)?: "\(category.label): сумата на декар трябва да е по-голяма от нула."
        case .roundsToNothing(let category)?:
            "\(category.label): върху \(Num.text(CropFields.double(crop.areaDca))) дка сумата се закръглява до нула."
        case .tooLarge(let category)?: "\(category.label): сумата е прекалено голяма."
        case .tooManyLines?: "Най-много \(CropSheet.maxLines) реда в един разход."
        }
    }

    /// The crop's last sheet, once per crop, when it is first chosen. Failing
    /// costs only the prefill, as for «Общи»: an empty sheet is still a
    /// sheet. Marked done only once answered, so a crop left mid-request is
    /// asked again when it is chosen again.
    private func prefillCrop() async {
        guard let crop = chosenCrop, !cropsPrefilled.contains(crop.commodity) else { return }
        do {
            let defaults = try await CostsAPI.loadCropDefaults(crop.commodity)
            guard !Task.isCancelled, commodity == crop.commodity else { return }
            cropsPrefilled.insert(crop.commodity)
            cropSheet.prefill(from: defaults, currency: currency)
        } catch let APIClient.APIError.http(_, code, _, _, _) where code == "UNKNOWN_COMMODITY" {
            cropsPrefilled.insert(crop.commodity)
            unrecognisedCrops.insert(crop.commodity)
        } catch {
            if !Task.isCancelled { cropsPrefilled.insert(crop.commodity) }
        }
    }

    /// The farm's last overhead values and the machine register, once, when
    /// «Общи» is first chosen. Either failing costs only the prefill: the
    /// sheet is still a sheet, and a farm with no history gets empty fields
    /// rather than an error (an empty `overheads` is the first run).
    private func prefillOverheads() async {
        guard !overheadPrefilled else { return }
        overheadPrefilled = true
        if let defaults = try? await CostsAPI.loadDefaults() {
            // Into the sheet's currency: a leva figure converted at the fixed
            // rate, and said so; one in any other currency left out. The
            // owner chose EUR over following the farm's last currency.
            overhead.prefill(from: defaults, currency: currency)
        }
        machinery = try? await CostsAPI.loadMachinery()
        // The register's figure, where the farm has no amortisation of its own
        // on record; «Използвай» puts it over one that is.
        overhead.useRegister(machinery?.offered, onlyIfEmpty: true)
    }

    /// The sheet as ONE write (#260, agri-saas #1604): every line lands or
    /// none does, so there is no half-saved sheet to explain. One key for
    /// the sheet, minted from all of it (`CostIdempotencyKey`: this sheet's
    /// nonce, every line's content), so a replay of the same sheet cannot
    /// book it twice and a corrected sheet is a new write.
    ///
    /// The outcomes are the same on both sides (`Failure.init`): a refusal,
    /// or a request that never left the phone, wrote nothing, so the sheet
    /// stays editable and goes again on «Запази»; a lost answer locks it
    /// (`answerLost`).
    ///
    /// The date goes as yyyy-mm-dd IN THE DEVICE'S ZONE (`BgDate.isoDay`).
    /// It once went through `.iso8601`, which is GMT, and a cost dated 25.09
    /// between midnight and 03:00 was booked to the 24th.
    private func saveSheet() async {
        guard canSave else { return }
        let currency = currency.trimmingCharacters(in: .whitespaces).uppercased()
        let day = BgDate.isoDay(incurredOn)
        let lines: [CreateCostEntry]
        switch scope {
        case .crop:
            guard let crop = chosenCrop else { return }
            lines = cropSheet.drafts(crop: crop, currency: currency, incurredOn: day)
        case .overhead:
            lines = overhead.drafts(currency: currency, incurredOn: day)
        }
        saving = true
        failure = nil
        defer { saving = false }
        let sheet = CostsAPI.Sheet(lines: lines)
        do {
            _ = try await CostsAPI.createSheet(
                sheet, idempotencyKey: CostIdempotencyKey.mint(nonce: nonce, draft: sheet))
            onSaved()
            dismiss()
        } catch {
            failure = Failure(error)
        }
    }
}
