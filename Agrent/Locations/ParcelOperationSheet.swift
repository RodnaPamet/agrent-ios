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
/// ── SAFE TO RETRY, and it is the first write in this app that is ──
///
/// `field-operation` is one of the four usecases honouring
/// `Idempotency-Key`, so a replay produces one operation. The cost row,
/// the exchange listing and the deactivation are all the other way, and
/// this sheet is therefore the one place an outbox could replay without
/// thinking. The key is minted once and held across attempts.
struct ParcelOperationSheet: View {
    let locationID: String
    let parcel: Parcel
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = OperationReferenceStore()
    @State private var creatingProduct = false
    @State private var me: CurrentUser?

    @State private var kind: Kind = .spray
    @State private var product: InputItem?
    @State private var doseText = ""
    @State private var doseUnit: Unit?
    @State private var waterText = ""
    @State private var waterUnit: Unit?
    @State private var technique: ApplicationTechnique = .boom
    @State private var note = ""

    @State private var saving = false
    @State private var failure: String?

    /// Can this failure be fixed by trying later?
    ///
    /// The distinction the outbox turns on. A 400 is the server
    /// disagreeing and will disagree tomorrow; no signal is a condition
    /// that passes. Only the second may be queued — see
    /// `PendingOperations.isWorthRetrying`.
    @State private var failureIsRetriable = false
    @State private var queued = false

    /// Minted ONCE per logical operation and reused across retries. A new
    /// key per attempt defeats the dedupe entirely.
    @State private var idempotencyKey = UUID().uuidString

    enum Kind: String, CaseIterable, Identifiable {
        case spray = "SPRAY"
        case fertilize = "FERTILIZE"
        var id: String { rawValue }
        var label: String { self == .spray ? "Пръскане" : "Торене" }
    }

    /// The split is a NEGATION. 24 items on this tenant: 13 PESTICIDE, 8
    /// FERTILIZER, 3 AMENDMENT — so `!= FERTILIZER` gives 16 products and
    /// `== PESTICIDE` would hide three the farm owns.
    private var choices: [InputItem] {
        let all = store.items.value ?? []
        return all.filter { kind == .fertilize ? $0.isFertilizer : !$0.isFertilizer }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
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
            productItemId: spraying ? product?.id : nil,
            doseValue: spraying ? dose : nil,
            doseUnitId: spraying ? doseUnit?.id : nil,
            waterRateValue: spraying ? decimal(waterText) : nil,
            waterRateUnitId: spraying ? waterUnit?.id : nil,
            fertilizerItemId: spraying ? nil : product?.id,
            fertilizerDoseValue: spraying ? nil : dose,
            fertilizerDoseUnitId: spraying ? nil : doseUnit?.id,
            // THE SLUG, never the label — it prints raw onto the ДНЕВНИК.
            applicationTechnique: technique.rawValue,
            targetNote: note.isEmpty ? nil : note
        )
    }

    private var canSave: Bool { !saving && draft.problems.isEmpty && me != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Операция", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) {
                        // The two lists are disjoint, so a selection made
                        // for one kind is never valid for the other.
                        product = nil
                    }
                }

                Section(kind == .spray ? "Препарат" : "Тор") {
                    // `.value == nil` is TRUE FOR A FAILURE as well as for
                    // a load in progress, so this spun forever when the
                    // items decode broke — a screen that had nothing to
                    // say and said it indefinitely. Matched on the state,
                    // not on the absence of a value.
                    switch store.items {
                    case .loading:
                        ProgressView()
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Опитайте отново") { Task { await store.load() } }
                                .font(.footnote)
                        }
                    case .loaded:
                    if choices.isEmpty {
                        Text("Няма въведени артикули от този вид.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Избор", selection: $product) {
                            Text("— изберете —").tag(InputItem?.none)
                            ForEach(choices) { Text($0.name).tag(InputItem?.some($0)) }
                        }
                        .onChange(of: product) {
                            // The item's own default unit, when it has one
                            // and it is a rate. Saves a tap on the common
                            // case without preventing a different choice.
                            if let unit = product?.defaultUnit,
                               units.contains(where: { $0.id == unit.id }) {
                                doseUnit = unit
                            }
                        }
                    }

                    // The archetype warning, at the moment of choosing.
                    //
                    // 22 of this tenant's 24 products are `Generic …` with
                    // no active ingredient and no PPP number. They are
                    // seeded placeholders meant to be replaced, and this
                    // is the screen where an unreplaced one becomes a row
                    // in a regulated column of a filed register. Said here
                    // rather than on the entry afterwards, because here is
                    // where it can still be changed.
                    if let chosen = product, chosen.isArchetype {
                        Label(
                            "Това е образцов продукт без търговско наименование и без "
                          + "рег. № по ЗЗР. Дневникът ще се подаде с празни колони.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    }

                    Button {
                        creatingProduct = true
                    } label: {
                        Label("Нов продукт", systemImage: "plus.circle")
                    }
                }

                Section("Доза") {
                    LabeledContent("Количество") {
                        TextField("0", text: $doseText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Мерна единица", selection: $doseUnit) {
                        Text("—").tag(Unit?.none)
                        ForEach(units) { Text($0.symbol).tag(Unit?.some($0)) }
                    }
                }

                if kind == .spray {
                    Section("Работен разтвор") {
                        LabeledContent("Количество") {
                            TextField("по избор", text: $waterText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Picker("Мерна единица", selection: $waterUnit) {
                            Text("—").tag(Unit?.none)
                            ForEach(units) { Text($0.symbol).tag(Unit?.some($0)) }
                        }
                    }
                }

                Section {
                    Picker("Техника", selection: $technique) {
                        ForEach(ApplicationTechnique.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    // Said here because it changes what an operator should
                    // expect to see later: this value is printed verbatim
                    // on the filed register.
                    Text("Техниката се записва в ДНЕВНИКА така, както е избрана.")
                }

                Section("Бележка") {
                    TextEditor(text: $note).frame(minHeight: 80)
                }

                if let problem = problemText {
                    Section { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                }
                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(Palette.error)
                        // The ONLY write in this app that may say this.
                        Text("Може да опитате отново — повторното изпращане не създава втора операция.")
                            .font(.footnote).foregroundStyle(.secondary)

                        // Offered only when a later attempt could work. A
                        // refusal must not be queueable: it would sit in
                        // the outbox forever under a label promising it is
                        // on its way.
                        if failureIsRetriable {
                            Button {
                                Task { await queueForLater() }
                            } label: {
                                Label("Запази за по-късно", systemImage: "tray.and.arrow.down")
                            }
                            Text("Записът остава на устройството и се изпраща "
                               + "автоматично, когато има връзка.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .inlineTitle(parcel.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Запиши") { Task { await save() } }.disabled(!canSave) }
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $creatingProduct) {
            NewProductView(
                onCreated: { created in
                    // Adopted locally rather than refetched: the list is
                    // cached, and a round trip here would either show a
                    // stale picker or spend a spinner on data already in
                    // hand. The server just returned the row.
                    store.adopt(created)
                    product = created
                },
                existing: store.items.value ?? []
            )
        }
        .task {
                await store.load()
                me = await CurrentUserStore.shared.load()
            }
        }
    }

    private var problemText: String? {
        switch draft.problems.first {
        case .inputMissing: return kind == .spray
            ? "Изберете препарат." : "Изберете тор."
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
        defer { saving = false }
        do {
            _ = try await LocationsAPI.createOperation(
                locationID: locationID, draft, idempotencyKey: idempotencyKey)
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
            failureIsRetriable = PendingOperations.isWorthRetrying(error)
        }
    }

    /// Keep it, and send it when there is signal.
    ///
    /// The sheet already holds the data safely — on failure it stays open
    /// with everything intact. What it cannot survive is being dismissed,
    /// or the app being killed, and in a field the wait for signal can be
    /// hours. This is the difference between "your work is safe while you
    /// stand here holding the phone" and "your work is safe".
    private func queueForLater() async {
        guard let body = try? await APIClient.shared.encodeBody(draft) else {
            failure = "Операцията не можа да бъде запазена на устройството."
            return
        }
        await OutboxStore.shared.enqueue(PendingOperation(
            id: idempotencyKey,
            locationID: locationID,
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

    /// Add a just-created product to the loaded list, in place.
    ///
    /// The cached payload on disk is now one row short of the truth, which
    /// is correct rather than a bug: the next network-first load replaces
    /// it wholesale. What must not happen is the picker disagreeing with
    /// what the person just created, in the same breath.
    func adopt(_ item: InputItem) {
        guard case .loaded(let items, let freshness) = items else { return }
        self.items = .loaded(items + [item], freshness)
    }

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
