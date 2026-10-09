import SwiftUI

/// Log a spray or a fertiliser application on one parcel.
///
/// ── This is what the web's parcel tap actually does ──
///
/// It was asked for as "a new task modal". There is no such flow: the web
/// has no parcel-click-to-task handler anywhere, and `NewTaskModal` is
/// mounted only by the calendar and the linked-tasks panel. What a parcel
/// tap opens is this — a FIELD OPERATION, which is a different record with
/// a different endpoint and a different legal weight.
///
/// ── EDITOR AND ABOVE ──
///
/// `createFieldOperation` calls `assertCanWrite`, which is `ROLE_ORDER >=
/// 3`. MECHANISATOR is 1 and cannot create one — an operator's job is
/// COMPLETION, not creation. So this sheet is offered to the roles that
/// can use it, and the affordance is gated rather than the refusal being
/// discovered at submit.
///
/// The gate FAILS OPEN — see `CurrentUser.mayCreateOperations`. Hiding a
/// button from somebody who could have used it is worse than showing one
/// that might be refused.
///
/// ── SAFE TO RETRY, and the only write this app DOES retry ──
///
/// `field-operation` honours `Idempotency-Key`, so a replay produces one
/// operation. The key is minted ONCE and held across attempts — that is
/// what makes the outbox legitimate here, and a fresh key per attempt
/// would defeat the dedupe entirely.
///
/// Read the licence narrowly. It is for THIS write, and the reason is not
/// "this is the only route that dedupes":
///
///   - The exchange listing and the deactivation honour no key at all. A
///     replay puts a second offer on a public board. Never queue them.
///   - `POST /grain/costs` DOES honour the header, and has sent a key since
///     2026-09-25 — so the old wording here ("the cost row is the other
///     way", "the one place an outbox could replay") is wrong twice over.
///     But its key is minted PER DRAFT and re-minted when the content
///     changes, and nothing replays it. Queueing a cost would mean deciding
///     what a queued row means after the operator has moved on and possibly
///     re-entered it by hand, and nobody has decided that. Route safety is
///     a precondition for a queue, not a licence for one.
struct ParcelOperationSheet: View {
    let locationID: String
    let parcel: Parcel
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = OperationReferenceStore()
    @State private var me: CurrentUser?

    @State private var kind: Kind = .spray
    /// The product's trade name, typed (#237) — see `TypedProduct`.
    @State private var productText = ""
    /// A new product's ПРЗ № and quarantine period, asked only when the
    /// typed name is new on the spray path (`asksRegistration`).
    @State private var pppText = ""
    @State private var quarantineText = ""
    /// What a NEW name under «Пръскане» becomes — a fertiliser can be sprayed.
    @State private var newCategory: CreateFieldOperation.NewProductCategory = .pesticide
    @State private var doseText = ""
    @State private var doseUnit: Unit?
    @State private var waterText = ""
    @State private var waterUnit: Unit?
    @State private var technique: ApplicationTechnique = .boom
    @State private var note = ""

    @State private var saving = false
    @State private var failure: String?

    /// Can this failure be fixed later — and by what?
    ///
    /// The distinction the outbox turns on. A 400 is the server
    /// disagreeing and will disagree tomorrow; no signal is a condition
    /// that passes, and so, once the operator updates, is a build the
    /// server has retired (#169). Only those may be queued — see
    /// `QueueOffer.after(_:)`.
    @State private var queueOffer: QueueOffer = .notOffered
    @State private var queued = false

    /// The error behind `failure`, kept for ONE reason: a 429 that is then
    /// queued for later closes the outbox's pause — see `queueForLater`.
    @State private var failureError: Error?

    /// A refused save, played here because a refused sheet stays open. The
    /// success is played by the presenter, from `onSaved` — see
    /// `WriteFeedback`.
    @State private var feedback = WriteFeedback()

    /// Minted ONCE per logical operation and reused across retries. A new
    /// key per attempt defeats the dedupe entirely.
    @State private var idempotencyKey = UUID().uuidString

    enum Kind: String, CaseIterable, Identifiable {
        case spray = "SPRAY"
        case fertilize = "FERTILIZE"
        var id: String { rawValue }
        var label: String { self == .spray ? "Пръскане" : "Торене" }
    }

    /// «Запази за по-късно» after a failed save: offered or not, and what
    /// the line under it promises. Decided from the error alone, and PURE,
    /// so a test can read the decision — nothing in the unit suite renders
    /// this sheet.
    enum QueueOffer: Equatable {
        /// A refusal. It will be a refusal tomorrow, and a queued one would
        /// sit in the outbox forever under a label promising it is on its way.
        case notOffered
        /// No signal, a 5xx, a 408 or a 429: a later attempt can land, and
        /// the outbox makes it (`PendingOperations.isWorthRetrying`).
        case retry
        /// A 426: the server's version gate turned THIS BUILD away before
        /// the route ran (#169). Nothing about the record was looked at, so a
        /// build the server still serves will send it as it stands — kept on
        /// the phone for the updated app, where the web keeps nothing.
        case afterUpdate

        static func after(_ error: Error) -> QueueOffer {
            // The 426 FIRST. The retry policy calls it final, which is right
            // for the drain and for a parcel line's tap, and is exactly what
            // this case overrides for a record typed in a field.
            if case APIClient.APIError.clientTooOld = error { return .afterUpdate }
            return PendingOperations.isWorthRetrying(error) ? .retry : .notOffered
        }

        /// The line under the button — what happens to the record next — or
        /// nil when there is no button. The 426's names the update, not a
        /// connection: signal will not send it, and «автоматично» would
        /// promise something only the operator can start, as the outbox
        /// banner's own too-old line takes care not to.
        var caption: String? {
            switch self {
            case .notOffered:
                nil
            case .retry:
                "Записът остава на устройството и се изпраща автоматично, когато има връзка."
            case .afterUpdate:
                "Записът остава на устройството и се изпраща след обновяване на приложението."
            }
        }
    }

    /// The typed name against the farm's catalogue — see `TypedProduct`.
    ///
    /// The picker this replaces (owner, 2026-10-09: «remove all sample
    /// products and leave the product as free text only») offered 22 seeded
    /// «Generic …» archetypes among the farm's 24 products, and a job planned
    /// with one could never be completed (agri-saas #1078).
    ///
    /// While the catalogue is not in hand nothing can be matched, so a name
    /// counts as NEW: the two registration fields are asked for, and the
    /// server ignores them should it find the product after all. The other
    /// way round would be a refusal in a field.
    private var typed: TypedProduct {
        guard let catalogue = store.items.value else {
            return TypedProduct.cleaned(productText).isEmpty ? .empty : .new
        }
        return TypedProduct.classify(productText, spraying: kind == .spray, catalogue: catalogue)
    }

    private var suggestions: [InputItem] {
        TypedProduct.suggestions(for: productText, spraying: kind == .spray, in: store.items.value ?? [])
    }

    /// The name that goes out: the STORED one on a match, so the server meets
    /// exactly the row matched here; otherwise the typed one, trimmed.
    private var sentName: String? {
        if case .existing(let item) = typed { return item.name }
        let name = TypedProduct.cleaned(productText)
        return name.isEmpty ? nil : name
    }

    /// A new name under «Пръскане» asks what it is — a fertiliser can be
    /// sprayed — and only a new PESTICIDE needs its registration; a new
    /// fertiliser, on either path, needs neither.
    private var isNewSprayProduct: Bool { kind == .spray && typed == .new }
    private var asksRegistration: Bool { isNewSprayProduct && newCategory == .pesticide }

    private var quarantineDays: Int? {
        guard let days = Int(quarantineText.trimmingCharacters(in: .whitespacesAndNewlines)),
              days >= 0 else { return nil }
        return days
    }

    private var registration: CreateFieldOperation.NewProductRegistration? {
        let number = pppText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard asksRegistration, !number.isEmpty, let days = quarantineDays else { return nil }
        return .init(pppRegistrationNo: number, quarantinePeriodDays: days)
    }

    /// Why the typed name cannot go yet — said before the request, as the
    /// draft's own problems are, and first among them: a plant protection
    /// product on the fertiliser path is the thing to fix before its dose.
    /// (Only that way round — a fertiliser may be sprayed; `TypedProduct`.)
    private var typedProblem: String? {
        switch typed {
        case .wrongKind(let item):
            return "«\(item.name)» не е тор. Запишете го като „Пръскане“."
        case .sample(let item):
            return "«\(item.name)» е образцов продукт. Въведете истинското търговско наименование."
        case .new where asksRegistration && registration == nil:
            return "За нов препарат въведете рег. № по ЗЗР и карантинния срок в дни."
        case .new where TypedProduct.isTooLong(productText):
            return "Наименованието е твърде дълго — до \(TypedProduct.maxLength) знака."
        case .empty, .existing, .new:
            return nil
        }
    }

    private var units: [Unit] { store.units.value ?? [] }

    private func decimal(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: WireDecimal.wireLocale)
    }

    private var draft: CreateFieldOperation {
        let dose = decimal(doseText)
        let spraying = kind == .spray
        return CreateFieldOperation(
            operationType: kind.rawValue,
            parcelIds: [parcel.id],
            // SELF-ASSIGNED, from `/api/auth/me`. The field is
            // `z.string().min(1)` — required, not nullable, unlike the
            // same-named field on task creation one route away.
            //
            // Self rather than a roster because the person tapping a
            // parcel in a field is logging their own work. `/users/
            // assignable` exists and is reachable by the roles that can
            // create operations at all, so assigning somebody else is a
            // later feature rather than a blocked one — and it carries
            // colleague emails, which is a reason not to fetch it until
            // something renders it.
            assigneeUserId: me?.id,
            productName: spraying ? sentName : nil,
            doseValue: spraying ? dose : nil,
            doseUnitId: spraying ? doseUnit?.id : nil,
            waterRateValue: spraying ? decimal(waterText) : nil,
            waterRateUnitId: spraying ? waterUnit?.id : nil,
            fertilizerName: spraying ? nil : sentName,
            fertilizerDoseValue: spraying ? nil : dose,
            fertilizerDoseUnitId: spraying ? nil : doseUnit?.id,
            newProductCategory: isNewSprayProduct ? newCategory : nil,
            newProductRegistration: registration,
            // THE SLUG, never the label — it prints raw onto the ДНЕВНИК.
            applicationTechnique: technique.rawValue,
            targetNote: note.isEmpty ? nil : note
        )
    }

    private var canSave: Bool { !saving && draft.problems.isEmpty && typedProblem == nil && me != nil }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    Picker("Операция", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section(titled: kind == .spray ? "Препарат" : "Тор") {
                    // Kept across a switch of kind: the name may be right and
                    // the kind wrong, and `typed` reads it again either way.
                    TextField("Търговско наименование", text: $productText,
                              prompt: .fieldPrompt("Търговско наименование"))
                        .autocorrectionDisabled()

                    // The farm's own products the typed text is part of — a
                    // tap takes the stored name rather than a near-copy.
                    ForEach(suggestions) { item in
                        Button(item.name) { productText = item.name }
                            .accessibilityHint("Попълва това наименование")
                    }

                    switch typed {
                    case .existing:
                        productNote("Продуктът е в каталога на стопанството.")
                    case .new where kind == .fertilize:
                        productNote("Нов тор — ще бъде добавен в каталога на стопанството.")
                    case .empty, .new, .wrongKind, .sample:
                        EmptyView()
                    }

                    // `.value == nil` is TRUE FOR A FAILURE as well as for
                    // a load in progress, so this is matched on the state.
                    // Without the catalogue a name counts as new (`typed`).
                    if case .failed(let message) = store.items {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Опитайте отново") { Task { await store.load() } }
                                .font(.footnote)
                        }
                    }
                }

                if isNewSprayProduct {
                    Section {
                        Picker("Вид", selection: $newCategory) {
                            ForEach(CreateFieldOperation.NewProductCategory.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if asksRegistration { registrationFields }
                    } header: {
                        SectionHeader("Нов продукт")
                    } footer: {
                        SectionFooter {
                            // Said because it is asked only once: the product
                            // keeps them, and the next spray of it does not.
                            Text(newCategory == .pesticide
                                 ? "Продуктът не е в каталога на стопанството. ДНЕВНИКЪТ изисква "
                                   + "регистрационния му номер и карантинния срок в дни — записват се "
                                   + "веднъж, с него."
                                 : "Продуктът не е в каталога на стопанството и ще бъде добавен като "
                                   + "тор — без рег. № и карантинен срок.")
                        }
                    }
                }

                Section(titled: "Доза") {
                    FieldRow("Количество") {
                        TextField("0", text: $doseText, prompt: .fieldPrompt("0"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    MenuPicker("Мерна единица", selection: $doseUnit, value: doseUnit?.symbol ?? "—") {
                        Text("—").tag(Unit?.none)
                        ForEach(units) { Text($0.symbol).tag(Unit?.some($0)) }
                    }
                }

                if kind == .spray {
                    Section(titled: "Работен разтвор") {
                        FieldRow("Количество") {
                            TextField("по избор", text: $waterText, prompt: .fieldPrompt("по избор"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        MenuPicker("Мерна единица", selection: $waterUnit, value: waterUnit?.symbol ?? "—") {
                            Text("—").tag(Unit?.none)
                            ForEach(units) { Text($0.symbol).tag(Unit?.some($0)) }
                        }
                    }
                }

                Section {
                    MenuPicker("Техника", selection: $technique, value: technique.label) {
                        ForEach(ApplicationTechnique.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    SectionFooter {
                        // Said here because it changes what an operator should
                        // expect to see later: this value is printed verbatim
                        // on the filed register.
                        Text("Техниката се записва в ДНЕВНИКА така, както е избрана.")
                    }
                }

                Section(titled: "Бележка") {
                    TextEditor(text: $note).frame(minHeight: 80)
                }

                if let problem = problemText {
                    Section { Text(problem).font(.footnote).foregroundStyle(Palette.secondaryText) }
                }
                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(Palette.error)
                        // The ONLY write in this app that may say this.
                        Text("Може да опитате отново — повторното изпращане не създава втора операция.")
                            .font(.footnote).foregroundStyle(Palette.secondaryText)

                        // Offered only when a later attempt could work, or
                        // a later build (#169). A refusal must not be
                        // queueable: it would sit in the outbox forever
                        // under a label promising it is on its way.
                        if let promise = queueOffer.caption {
                            Button {
                                Task { await queueForLater() }
                            } label: {
                                Label("Запази за по-късно", systemImage: "tray.and.arrow.down")
                            }
                            Text(promise)
                                .font(.footnote).foregroundStyle(Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .inlineTitle(parcel.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else {
                        Button("Запиши") { Task { await save() } }
                            .disabled(!canSave)
                            .accessibilityInputLabels(A11y.Spoken.record)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .writeFeedback(feedback)
            .onChange(of: typed) { _, now in
                // The product's own default unit, once the name is one the
                // farm has and no unit is chosen yet — the picker's old
                // courtesy, kept.
                if case .existing(let item) = now, doseUnit == nil,
                   let unit = item.defaultUnit, units.contains(where: { $0.id == unit.id }) {
                    doseUnit = unit
                }
            }
        .task {
                await store.load()
                me = await CurrentUserStore.shared.load()
            }
        }
    }

    /// A new PESTICIDE's ПРЗ № and quarantine period (`asksRegistration`).
    @ViewBuilder
    private var registrationFields: some View {
        FieldRow("Рег. № по ЗЗР") {
            TextField("Номер", text: $pppText, prompt: .fieldPrompt("Номер"))
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
        // The unit in the prompt, not the title: «Карантинен срок, дни» was
        // cut to «Карантинен срок,…» at the DEFAULT size beside its field
        // (A11yShots 18).
        FieldRow("Карантинен срок") {
            TextField("дни", text: $quarantineText, prompt: .fieldPrompt("дни"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func productNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var problemText: String? {
        if let typedProblem { return typedProblem }
        switch draft.problems.first {
        case .inputMissing: return kind == .spray
            ? "Въведете препарат." : "Въведете тор."
        case .doseMissing: return "Дозата и мерната единица са задължителни."
        case .doseNotPositive: return "Дозата трябва да е по-голяма от нула."
        case .inputAmbiguous: return "Изберете само едно от двете."
        case .noParcel: return "Липсва парцел."
        case nil:
            // The one precondition that is not about the form: an
            // operation must name who is doing it, and the app cannot
            // write one until it knows who that is.
            return me == nil ? "Изчакване на потребителския профил…" : nil
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        failure = nil
        failureError = nil
        defer { saving = false }
        do {
            _ = try await LocationsAPI.createOperation(
                locationID: locationID, draft, idempotencyKey: idempotencyKey)
            onSaved()
            dismiss()
        } catch {
            failure = CreateFieldOperation.failureText(error)
            queueOffer = QueueOffer.after(error)
            failureError = error
            feedback.refused()
            // A 426 is about this BUILD, so it is the outbox's answer too:
            // told now, its banner says why nothing is being sent instead of
            // offering «Изпрати» for the same 426 (#168). Told HERE, before
            // «Запази за по-късно» can be tapped, so a record kept on a 426
            // joins a queue that already waits for the update (#169).
            OutboxStore.shared.absorbClientTooOld(error)
        }
    }

    /// Keep it, and send it when there is signal.
    ///
    /// The sheet already holds the data safely — on failure it stays open
    /// with everything intact. What it cannot survive is being dismissed,
    /// or the app being killed, and in a field the wait for signal can be
    /// hours. This is the difference between "your work is safe while you
    /// stand here holding the phone" and "your work is safe".
    ///
    /// ── A 429 here is the outbox's 429 too ──
    ///
    /// The live save and the outbox post to the SAME route and draw on the
    /// same budget, so a queued item that knew nothing of the refusal would
    /// be sent by the next foreground flush inside the window — a request
    /// spent to be told the same thing. So the error closes the outbox's
    /// pause before the item joins the queue, and the banner shows the wait
    /// instead of «Изпрати». Any other error is not a 429 and changes
    /// nothing. «Запиши» stays enabled: a live retry is the operator's call,
    /// and «повторното изпращане не създава втора операция» is still true of
    /// one.
    ///
    /// ── A 426 is kept too, for the updated app (#169) ──
    ///
    /// The server's version gate turned the BUILD away before the route ran,
    /// so nothing about the record was refused, and a build the server still
    /// serves will send it as it stands. The owner chose (2026-10-07) to keep
    /// it rather than have a farmer retype a spray after updating. The web
    /// shows its error and keeps nothing; this is a deliberate divergence
    /// (PARITY.md, Locations).
    ///
    /// Nothing goes out from THIS build: `save()` has already told the
    /// outbox, so every trigger is a no-op for the rest of the process
    /// (`OutboxStore.isClientTooOld`) and its banner says the records wait
    /// for the update. The updated app is a new process, which asks again
    /// and sends it — under the same key, as the person who recorded it,
    /// exactly as after no signal. The pause line below is a no-op for it:
    /// a 426 is not a 429.
    private func queueForLater() async {
        guard let body = try? await APIClient.shared.encodeBody(draft) else {
            failure = "Операцията не можа да бъде запазена на устройството."
            feedback.refused()
            return
        }
        if let failureError { OutboxStore.shared.pause.absorb(failureError) }
        await OutboxStore.shared.enqueue(PendingOperation(
            id: idempotencyKey,
            locationID: locationID,
            // WHO recorded it, so it is sent only under their session and
            // parked — not sent, not shown — while anyone else is signed in
            // (agri-saas#1191 P0.9). `canSave` requires `me`, so this is
            // never nil from here.
            ownerUserID: me?.id,
            parcelSummary: "\(parcel.name) · \(kind.label)",
            payload: body,
            createdAt: Date(),
            attempts: 0,
            lastAttemptAt: nil,
            lastError: failure
        ))
        queued = true
        onSaved()
        dismiss()
    }
}

/// Items and rate units.
///
/// Both are effectively static — `Unit` has no write path and the server
/// caches the list for 24h — so both go through `CachedResource` and are
/// available with no signal, which is the case this sheet exists for.
@Observable
@MainActor
final class OperationReferenceStore {
    private(set) var items: LoadState<[InputItem]> = .loading
    private(set) var units: LoadState<[Unit]> = .loading

    func load() async {
        if items.value == nil {
            await CachedResource.loadShowingCacheFirst(LocationsAPI.itemsPath) {
                try await LocationsAPI.decodeItems(from: $0)
            } publish: { [weak self] in self?.items = $0 }
        }
        if units.value == nil {
            await CachedResource.loadShowingCacheFirst(LocationsAPI.rateUnitsPath) {
                try await LocationsAPI.decodeUnits(from: $0)
            } publish: { [weak self] in self?.units = $0 }
        }
    }
}
