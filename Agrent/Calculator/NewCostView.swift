import SwiftUI

/// Add a cost to the farm's books.
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
    let onSaved: () -> Void

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
        /// One cost for the crops' side of the books. The per-decare lines by
        /// crop replace this once agri-saas settles how a crop's area is
        /// counted (#1512); until then it is the one-line form, limited to
        /// the crop categories so the two halves do not overlap.
        case crop
        /// The year's overheads, each spread over the whole farm.
        case overhead
    }

    /// The «Общи» sheet and its prefill sources.
    @State private var overhead = OverheadSheet()
    @State private var machinery: MachineryDepreciation?
    @State private var overheadPrefilled = false
    @State private var currencyEdited = false

    @State private var category: CostCategory = .fuel
    @State private var amountText = ""
    /// EUR: Bulgaria's currency since 1 January 2026 (owner, 2026-10-10).
    /// Typed over for a cost in another currency.
    @State private var currency = "EUR"
    @State private var incurredOn = Date()
    @State private var supplier = ""
    @State private var notes = ""

    @State private var saving = false
    @State private var failure: Failure?

    private enum Failure: Equatable {
        /// The server answered and said no. The row does not exist.
        case refused(String)
        /// No answer arrived. The row may or may not exist, and only the
        /// books can say which.
        case unknown(String)

        var message: String {
            switch self {
            case .refused(let message), .unknown(let message): message
            }
        }
    }

    /// Parsed with an explicit locale, not `Decimal(string:)`'s default.
    /// A Bulgarian keyboard produces "12,50" and the wire wants 12.5; the
    /// device also reports en_BG, so neither the comma nor the full stop
    /// can be assumed. Both are accepted and normalised here.
    private var amount: Decimal? {
        let cleaned = amountText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var draft: CreateCostEntry? {
        guard let amount else { return nil }
        return CreateCostEntry(
            category: category,
            amount: amount,
            currency: currency.trimmingCharacters(in: .whitespaces).uppercased(),
            // yyyy-mm-dd, IN THE DEVICE'S ZONE.
            //
            // This was `.formatted(.iso8601.year().month().day()…)`, which
            // defaults to GMT. Bulgaria is UTC+3 in summer, so a cost the
            // farmer dated 25.09 went to the server as 2026-09-24 — measured:
            //
            //     picked  25.09.2026 г., 0:30
            //     sent    2026-09-24
            //
            // A `DatePicker` in `.date` mode keeps the time of day it opened
            // with, so every cost entered between midnight and 03:00 local was
            // booked to the previous day. In the farm's BOOKS. See
            // `BgDate.isoDay`, which is the write side of the parser that has
            // always pinned this contract.
            incurredOn: BgDate.isoDay(incurredOn),
            // `.recorded`, not `.isEmpty`. These mapped only EXACTLY empty, so
            // a supplier of three spaces went to the books as "   " — and,
            // because the idempotency key is a hash of this payload, it also
            // minted a different key from the omitted one, so editing a field
            // to whitespace and back would write a second row.
            supplier: supplier.recorded,
            description: notes.recorded
        )
    }

    private var canSave: Bool {
        guard !saving else { return false }
        switch scope {
        case .crop:
            guard let draft else { return false }
            return draft.problems.isEmpty
        case .overhead:
            // `problems` holds `.nothingEntered` for an empty sheet.
            return overhead.problems.isEmpty && !answerLost
        }
    }

    /// The last save's answer was lost: what was sent may be in the books.
    /// «Общи» is then not sent again from this sheet (the owner's rule for a
    /// cost, 2026-09-25: look at the list first), and the choice of side is
    /// fixed so the text saying so stays in front of the operator.
    private var answerLost: Bool {
        if case .unknown? = failure { true } else { false }
    }

    /// The crop side's categories: what a crop's decares carry — the
    /// overheads are «Общи»'s.
    private static let cropCategories: [CostCategory] = [.rent, .seed, .fuel, .pesticide, .fertilizer, .service]

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
                             ? "Един разход за култура. Разходите на декар по култура предстоят."
                             : "Годишни суми. Всяка се разпределя по площ върху цялото стопанство — "
                               + "земята без култура запазва своя дял.")
                    }
                }

                switch scope {
                case .crop: cropFields
                case .overhead:
                    // At the top, under the choice it fixes: a lost answer
                    // dims the whole sheet, and the reason belongs where the
                    // operator is looking, not under four sections.
                    if let failure {
                        Section { failureView(failure) }
                    }
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
                            Task { scope == .crop ? await save() : await saveOverheads() }
                        }
                        .disabled(!canSave)
                        .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task(id: scope) { if scope == .overhead { await prefillOverheads() } }
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

    /// The one-line form, as it always was — for the crop categories only.
    @ViewBuilder
    private var cropFields: some View {
        Section {
            // `MenuPicker`: the system menu picker cuts a Bulgarian
            // value short in the row (#160).
            MenuPicker("Категория", selection: $category, value: category.label) {
                ForEach(Self.cropCategories, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            // `.decimalPad` has no minus sign, which is right: the
            // server requires amount > 0 and a negative cost is a
            // different concept the books do not have here.
            TextField("Сума", text: $amountText, prompt: .fieldPrompt("Сума"))
                .keyboardType(.decimalPad)
            TextField("Валута", text: $currency, prompt: .fieldPrompt("Валута"))
                .textInputAutocapitalization(.characters)
            DatePicker("Дата", selection: $incurredOn, displayedComponents: .date)
                // The date while its calendar is open — see
                // `Palette.DatePill` (#164).
                .tint(Palette.DatePill.tint)
        }

        Section(titled: "Доставчик") {
            TextField("по избор", text: $supplier, prompt: .fieldPrompt("по избор"), axis: .vertical)
        }
        Section(titled: "Бележки") {
            TextEditor(text: $notes).frame(minHeight: 100)
        }

        if let problem = firstProblemText {
            Section { Text(problem).font(.footnote).foregroundStyle(Palette.secondaryText) }
        }

        if let failure {
            Section { failureView(failure) }
        }
    }

    /// The overhead sheet's currency and date: one each, for every line.
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
        case .refused(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(Palette.error)
                Text(scope == .crop
                     ? "Разходът НЕ е записан. Можете да опитате отново."
                     : "Нито една от сумите НЕ е записана. Можете да опитате отново.")
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
                Text(scope == .crop ? """
                    Връзката прекъсна, преди сървърът да отговори. Разходът \
                    може да е записан, а може и да не е. Проверете списъка с \
                    разходи, преди да го въведете отново — повторното \
                    въвеждане създава втори запис.
                    """ : """
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
        let outcome = switch (failure, scope) {
        case (.refused, .crop): "Разходът НЕ е записан."
        case (.refused, .overhead): "Нито една от сумите НЕ е записана."
        case (.unknown, .crop): "Разходът може да е записан, а може и да не е. Проверете списъка с разходи."
        case (.unknown, .overhead): "Сумите може да са записани, а може и да не са. Проверете списъка с разходи."
        }
        return "\(failure.message) \(outcome)"
    }

    private var firstProblemText: String? {
        guard !amountText.isEmpty, let draft else {
            return amountText.isEmpty ? nil : "Сумата не е разчетена."
        }
        switch draft.problems.first {
        case .amountNotPositive: return "Сумата трябва да е по-голяма от нула."
        case .amountTooLarge: return "Сумата е прекалено голяма."
        case .currencyMissing: return "Валутата е задължителна."
        case .dateMissing: return "Датата е задължителна."
        case nil: return nil
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

    /// The year's overheads as ONE write (#260, agri-saas #1604): every
    /// line lands or none does, so there is no half-saved sheet to explain.
    /// One key for the sheet, minted from all of it (`CostIdempotencyKey`:
    /// this sheet's nonce, every line's content), so a replay of the same
    /// sheet cannot book it twice and a corrected sheet is a new write.
    ///
    /// The outcomes are the one-line form's, for the sheet as a whole: a
    /// refusal wrote nothing, so the sheet stays editable and goes again on
    /// «Запази»; a lost answer locks it (`answerLost`).
    private func saveOverheads() async {
        guard canSave else { return }
        saving = true
        failure = nil
        defer { saving = false }
        let sheet = CostsAPI.Sheet(lines: overhead.drafts(
            currency: currency.trimmingCharacters(in: .whitespaces).uppercased(),
            incurredOn: BgDate.isoDay(incurredOn)))
        do {
            _ = try await CostsAPI.createSheet(
                sheet, idempotencyKey: CostIdempotencyKey.mint(nonce: nonce, draft: sheet))
            onSaved()
            dismiss()
        } catch let error as URLError {
            failure = .unknown(UserMessage.text(for: error))
        } catch {
            failure = .refused(UserMessage.text(for: error))
        }
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }

        do {
            // Minted HERE, from the draft being sent, not held in state. The
            // key is a function of content by construction, so it cannot go
            // stale behind an edit — which is the failure that would drop a
            // correction and leave the books wrong.
            _ = try await CostsAPI.create(
                draft, idempotencyKey: CostIdempotencyKey.mint(nonce: nonce, draft: draft)
            )
            onSaved()
            dismiss()
        } catch let error as URLError {
            // A transport failure is the ambiguous one: the request may
            // have reached the server and been written before the answer
            // was lost.
            failure = .unknown(UserMessage.text(for: error))
        } catch {
            // The server answered. Whatever it said, it said it — so the
            // row does not exist and trying again is safe.
            failure = .refused(UserMessage.text(for: error))
        }
    }
}
