import Foundation

/// «Коригирай» on a recorded treatment (agrent-ios #392; owner 2026-10-24):
/// who is offered it, what the form holds, and what goes out.
///
/// Pure, so the rules are read by a test rather than by tapping a form. The
/// API is `TreatmentCorrectionAPI`; the screens are `TreatmentCorrectionFlow`.
enum TreatmentCorrection {

    /// The journal row's own answer (`mayCorrect`, agri-saas #2292), never a
    /// probe of the write-gated GET.
    ///
    /// The rule is the withdrawal's today: creator or administrator, and one
    /// author across the treatment's tasks. It is its own field, and is NOT
    /// read through `mayDelete`, because agri-saas #2280 may narrow the
    /// withdrawal now that it is irreversible. A fallback to `mayDelete` would
    /// then hide «Коригирай» from creators who may still correct.
    ///
    /// Only an explicit `false` hides it. An absent flag is a page cached
    /// before the field existed, and the route checks again either way.
    nonisolated static func offered(_ entry: LogEntry, to me: CurrentUser?) -> Bool {
        guard let treatment = entry.treatment, treatment.isTreatment, treatment.isChemicalTreatment,
              treatment.treatmentGroupId != nil,
              let me, me.mayWrite else { return false }
        return treatment.mayCorrect ?? true
    }

    static let actionTitle = "Коригирай"

    /// A line with no treated area of its own: the parcel was treated whole.
    /// The definition doesn't carry the parcel's area, so it says so in words.
    static let wholeParcel = "Целият парцел"

    /// What the parcel list offers, and why no more (agri-saas #2304): the
    /// ДНЕВНИК prints one table per block, so a parcel of a block the
    /// treatment never had would be a treatment never recorded.
    static let parcelsNote =
        "Добавят се само парцели от блоковете на това мероприятие. Друг блок се записва като отделно мероприятие."
    static let areasNote = "Празното поле е целият парцел."

    /// Someone else corrected it after the form was opened (409 `STALE_DATA`).
    /// Their correction stands; this one would have overwritten it unseen.
    static let staleText =
        "Някой друг е коригирал мероприятието междувременно. Заредете го отново, "
        + "за да видите сегашните стойности. Вашите промени няма да бъдат запазени."
    static let reloadTitle = "Зареди отново"

    /// What a save hands the entry's screen: the corrected definition, and
    /// what it can't say by itself. The dose unit's symbol is the form's
    /// choice, as the definition names the unit by id. Whether an area moved
    /// decides whether the row's total area still holds.
    struct Saved: Equatable, Sendable {
        let definition: TreatmentDefinition
        let unitSymbol: String?
        let areaChanged: Bool
    }

    // MARK: - The body

    /// `PUT …/definition`, carrying only what the person changed.
    ///
    /// The server leaves an OMITTED field as it is (`correctDiaryTreatment`
    /// skips every `undefined`). So an untouched field is left out, which
    /// keeps a stored value this form can't show exactly, such as a technique
    /// outside the seven, from being rewritten. A field the person CLEARED
    /// goes out as an explicit `null`. A synthesized `Encodable` would drop
    /// it instead, and the server would read that as "unchanged".
    ///
    /// The parcels go out only when an area changed, and then every one of
    /// them, the set as recorded: a different set is refused.
    struct Body: Encodable, Equatable, Sendable {
        enum Field: String, CodingKey, CaseIterable, Sendable {
            case occurredOn, productItemId, targetNote, doseValue, doseUnitId
            case phenophase, quarantinePeriodDays, applicationTechnique, parcels
        }

        struct ParcelArea: Encodable, Equatable, Sendable {
            let parcelId: String
            /// Hectares. Nil is the whole parcel, sent as `null`: the key is
            /// required.
            let treatedAreaHa: Double?

            private enum CodingKeys: String, CodingKey { case parcelId, treatedAreaHa }

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(parcelId, forKey: .parcelId)
                try c.encodeOrNull(treatedAreaHa, forKey: .treatedAreaHa)
            }
        }

        let fields: Set<Field>
        let occurredOn: String
        let productItemId: String
        let targetNote: String?
        let doseValue: Decimal
        let doseUnitId: String
        let phenophase: String?
        let quarantinePeriodDays: Int?
        let applicationTechnique: String?
        let parcels: [ParcelArea]

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            for field in Field.allCases where fields.contains(field) {
                switch field {
                case .occurredOn: try c.encode(occurredOn, forKey: field)
                case .productItemId: try c.encode(productItemId, forKey: field)
                case .targetNote: try c.encodeOrNull(targetNote, forKey: field)
                case .doseValue: try c.encode(doseValue, forKey: field)
                case .doseUnitId: try c.encode(doseUnitId, forKey: field)
                case .phenophase: try c.encodeOrNull(phenophase, forKey: field)
                case .quarantinePeriodDays: try c.encodeOrNull(quarantinePeriodDays, forKey: field)
                case .applicationTechnique: try c.encodeOrNull(applicationTechnique, forKey: field)
                case .parcels: try c.encode(parcels, forKey: field)
                }
            }
        }
    }

    // MARK: - The form

    /// The form's fields, started from the definition as recorded.
    struct Draft: Equatable, Sendable {
        let original: TreatmentDefinition
        /// The recorded dose unit's symbol, from the journal row: the
        /// definition names the unit by id.
        let originalUnitSymbol: String?
        var date: Date
        /// The trade name, typed and matched against the farm's catalogue,
        /// as on «Ново мероприятие». Only a product the farm has can be
        /// chosen: a correction sends it by id (`resolve`).
        var productText: String
        /// The farm's product the typed name is, when it isn't the recorded
        /// one. Set by `resolve`.
        private(set) var product: InputItem?
        /// Why the typed name can't be used, when it can't. Set by `resolve`.
        private(set) var productIssue: ProductIssue?
        var doseText: String
        var doseUnit: DoseUnit
        var pestText: String
        var phenophaseText: String
        var quarantineText: String
        /// A slug (`ApplicationTechnique`), or a stored value outside the
        /// seven, kept as it is. Nil when none was recorded.
        var technique: String?
        /// Each parcel's treated area as typed, in decares, by parcel id.
        /// Empty is the whole parcel.
        var areaTexts: [String: String]
        /// The treatment's parcels as recorded, then the other parcels of its
        /// blocks once they are read (`offer`), each block's together.
        private(set) var parcels: [ParcelChoice]
        /// The parcels ticked: the set the correction keeps (agri-saas #2304).
        var chosen: Set<String>

        /// A parcel the list can show: recorded on the treatment, or in one of
        /// its blocks. `areaHa` is the parcel's own, nil until its block is
        /// read or when it has none.
        struct ParcelChoice: Equatable, Sendable, Identifiable {
            let id: String
            let name: String
            let blockID: String
            var areaHa: Double?
            /// On the treatment as recorded.
            let recorded: Bool
        }

        /// A dose unit by id, with the symbol the picker shows.
        struct DoseUnit: Hashable, Sendable {
            let id: String
            let symbol: String?
        }

        enum ProductIssue: Equatable, Sendable {
            /// The catalogue isn't in hand yet.
            case loading
            case notInCatalogue
            case wrongKind(String)
            case sample(String)
        }

        init(_ definition: TreatmentDefinition, unitSymbol: String? = nil, today: Date = Date()) {
            original = definition
            // The definition's own symbol first (agri-saas #2298); the
            // journal row's before it existed.
            originalUnitSymbol = definition.doseUnitSymbol?.recorded ?? unitSymbol
            date = definition.occurredOn.flatMap(BgDate.parseISODay) ?? today
            productText = definition.productName
            doseText = Self.doseText(definition.doseValue)
            doseUnit = DoseUnit(id: definition.doseUnitId, symbol: definition.doseUnitSymbol?.recorded ?? unitSymbol)
            pestText = definition.targetNote ?? ""
            phenophaseText = definition.phenophase ?? ""
            quarantineText = definition.quarantinePeriodDays.map(String.init) ?? ""
            technique = Self.slug(definition.applicationTechnique)
            var areas: [String: String] = [:]
            for line in definition.lines {
                areas[line.parcelId] = line.treatedAreaHa.map { Area(hectares: $0).number } ?? ""
            }
            areaTexts = areas
            parcels = definition.lines.map {
                ParcelChoice(id: $0.parcelId, name: $0.parcelName, blockID: $0.locationId, areaHa: nil, recorded: true)
            }
            chosen = Set(definition.lines.map(\.parcelId))
        }

        var kind: TreatmentDraft.Kind { original.treatmentKind ?? .spray }

        /// The fields only a spraying has, as on «Ново мероприятие».
        var spraying: Bool { kind == .spray }

        // MARK: The product

        /// The typed name against the farm's catalogue. The recorded name
        /// needs no catalogue: it is the product as recorded. A name the
        /// catalogue doesn't have can't be sent, because a correction names
        /// the product by id; recording a treatment is what adds a product.
        mutating func resolve(in catalogue: [InputItem]?) {
            product = nil
            productIssue = nil
            let name = TypedProduct.cleaned(productText)
            guard !name.isEmpty, name != original.productName else { return }
            guard let catalogue else {
                productIssue = .loading
                return
            }
            switch TypedProduct.classify(productText, spraying: spraying, catalogue: catalogue) {
            case .existing(let item):
                if item.id != original.productItemId { product = item }
            case .wrongKind(let item): productIssue = .wrongKind(item.name)
            case .sample(let item): productIssue = .sample(item.name)
            case .new: productIssue = .notInCatalogue
            case .empty: break
            }
        }

        // MARK: The dose

        var dose: Decimal? { TreatmentDraft.decimal(doseText) }

        /// «0,15», up to the column's four places, as the journal row writes
        /// a dose. Comma or point both read back (`TreatmentDraft.decimal`).
        static func doseText(_ value: Decimal) -> String {
            value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never).locale(BgDate.locale))
        }

        /// The picker's choices: the farm's dose units, and the recorded one
        /// first when it is none of them, or it couldn't be shown as chosen.
        func unitOptions(_ units: [Unit]) -> [DoseUnit] {
            let known = units.map { DoseUnit(id: $0.id, symbol: $0.symbol) }
            return known.contains { $0.id == original.doseUnitId }
                ? known
                : [DoseUnit(id: original.doseUnitId, symbol: originalUnitSymbol)] + known
        }

        /// The recorded unit's symbol from the farm's units, once they are
        /// in hand, for a row that had none to give.
        mutating func name(units: [Unit]) {
            guard doseUnit.symbol == nil, let unit = units.first(where: { $0.id == doseUnit.id }) else { return }
            doseUnit = DoseUnit(id: unit.id, symbol: unit.symbol)
        }

        private func doseLine(_ value: Decimal, _ symbol: String?) -> String {
            symbol.map { "\(Self.doseText(value)) \($0)" } ?? Self.doseText(value)
        }

        // MARK: The parcels

        /// The blocks the definition's lines are in, in the order they first
        /// appear: the only blocks a correction may add a parcel in.
        var blockIDs: [String] {
            var seen = Set<String>()
            return original.lines.map(\.locationId).filter { seen.insert($0).inserted }
        }

        /// The blocks' parcels, read: each recorded parcel's own area filled
        /// in, and the blocks' other parcels offered after the recorded ones,
        /// unticked, block by block in the blocks' order.
        mutating func offer(_ blocks: [TreatmentBlocks.Block]) {
            var byID: [String: Parcel] = [:]
            for block in blocks { for parcel in block.parcels { byID[parcel.id] = parcel } }
            for index in parcels.indices where parcels[index].recorded {
                parcels[index].areaHa = byID[parcels[index].id]?.areaHa
            }
            var known = Set(parcels.map(\.id))
            for block in blocks {
                let sorted = block.parcels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                for parcel in sorted where known.insert(parcel.id).inserted {
                    parcels.append(ParcelChoice(id: parcel.id, name: parcel.name, blockID: block.id,
                                                areaHa: parcel.areaHa, recorded: false))
                }
            }
        }

        /// The ticked parcels, in the list's order.
        var chosenParcels: [ParcelChoice] { parcels.filter { chosen.contains($0.id) } }

        /// A parcel's typed area: nil for the whole parcel, and not valid
        /// when it isn't an area over zero.
        func area(of id: String) -> (valid: Bool, area: Area?) {
            guard let text = areaTexts[id]?.recorded else { return (true, nil) }
            guard let area = Area.parse(decares: text), area.wireHectares > 0 else { return (false, nil) }
            return (true, area)
        }

        /// The area typed, or nil for the whole parcel, which is also what a
        /// typed area within the register's rounding of the parcel's own is,
        /// as on «Ново мероприятие» (`treatedAreas`). Typing the shown size
        /// back is no change. The whole parcel goes out as the parcel's own
        /// exact area (`body`).
        func sentArea(_ id: String) -> Area? {
            guard let typed = area(of: id).area else { return nil }
            if let own = parcels.first(where: { $0.id == id })?.areaHa.map(Area.init(hectares:)),
               !typed.differs(from: own) { return nil }
            return typed
        }

        /// Larger than the parcel, by more than the register rounds: the
        /// server refuses it (`TREATMENT_AREA_EXCEEDS_PARCEL`, inclusive).
        /// A parcel whose own area isn't known takes any area.
        private func tooLarge(_ parcel: ParcelChoice) -> Area? {
            guard let typed = area(of: parcel.id).area, let own = parcel.areaHa.map(Area.init(hectares:)),
                  typed.wireHectares > own.wireHectares, typed.differs(from: own) else { return nil }
            return own
        }

        private var setChanged: Bool { chosen != Set(original.lines.map(\.parcelId)) }

        /// A kept parcel whose area moved.
        private func areaChanged(_ line: TreatmentDefinition.Line) -> Bool {
            guard chosen.contains(line.parcelId) else { return false }
            guard area(of: line.parcelId).valid else { return false }
            switch (sentArea(line.parcelId), line.treatedAreaHa.map(Area.init(hectares:))) {
            case (nil, nil): return false
            case let (now?, was?): return now.differs(from: was)
            default: return true
            }
        }

        // MARK: The other fields

        /// A known technique by its slug whatever its case, so `Boom` and
        /// `boom` are one choice and an untouched one counts as unchanged.
        /// Anything else is kept as written.
        static func slug(_ stored: String?) -> String? {
            guard let trimmed = stored?.recorded else { return nil }
            return ApplicationTechnique(rawValue: trimmed.lowercased())?.rawValue ?? trimmed
        }

        /// The picker's choices: the seven, and the recorded value first when
        /// it is none of them, or «—» when nothing was recorded. A choice
        /// that isn't in the list can't be shown as selected.
        var techniqueOptions: [String?] {
            let known: [String?] = ApplicationTechnique.allCases.map(\.rawValue)
            guard let stored = Self.slug(original.applicationTechnique) else { return [nil] + known }
            return known.contains(stored) ? known : [stored] + known
        }

        static func techniqueLabel(_ slug: String?) -> String { ApplicationTechnique.display(slug) ?? "—" }

        // The values as they would go out: trimmed, and nil when empty,
        // which the server stores as "not captured".
        var day: String { BgDate.isoDay(date) }
        var targetNote: String? { pestText.recorded }
        var phenophase: String? { phenophaseText.recorded }

        /// The period typed, nil when the field is empty, and not valid when
        /// it isn't a whole number of days the server accepts (0 to 365).
        var quarantine: (valid: Bool, days: Int?) {
            guard let text = quarantineText.recorded else { return (true, nil) }
            guard let days = Int(text), (0...365).contains(days) else { return (false, nil) }
            return (true, days)
        }

        /// «Най-ранна дата за прибиране», from the date and the period, as
        /// the form for a new treatment computes it.
        var earliestHarvest: Date? {
            guard spraying, let days = quarantine.days else { return nil }
            return TreatmentCheck.earliestHarvest(after: date, days: days)
        }

        // MARK: What changed

        /// What differs from the record, in the form's order.
        var changed: [Body.Field] {
            var out: [Body.Field] = []
            if day != original.occurredOn { out.append(.occurredOn) }
            if product != nil { out.append(.productItemId) }
            if spraying, targetNote != original.targetNote?.recorded { out.append(.targetNote) }
            if let dose, dose != original.doseValue { out.append(.doseValue) }
            if doseUnit.id != original.doseUnitId { out.append(.doseUnitId) }
            if spraying {
                if phenophase != original.phenophase?.recorded { out.append(.phenophase) }
                if quarantine.valid, quarantine.days != original.quarantinePeriodDays {
                    out.append(.quarantinePeriodDays)
                }
                if technique != Self.slug(original.applicationTechnique) { out.append(.applicationTechnique) }
            }
            if setChanged || original.lines.contains(where: areaChanged) { out.append(.parcels) }
            return out
        }

        var body: Body {
            Body(fields: Set(changed), occurredOn: day,
                 productItemId: product?.id ?? original.productItemId,
                 targetNote: targetNote, doseValue: dose ?? original.doseValue, doseUnitId: doseUnit.id,
                 phenophase: phenophase, quarantinePeriodDays: quarantine.days, applicationTechnique: technique,
                 // A parcel treated whole as its own exact area, as on
                 // «Ново мероприятие» (owner, 2026-10-25); null only where
                 // the parcel's area isn't known.
                 parcels: chosenParcels.map { Body.ParcelArea(parcelId: $0.id,
                                                              treatedAreaHa: sentArea($0.id)?.wireHectares ?? $0.areaHa) })
        }

        enum Problem: Equatable, Sendable {
            case futureDate
            case productMissing
            case product(String)
            case pestMissing
            case pestTooLong
            case doseMissing
            case doseNotPositive
            case quarantineInvalid
            case quarantineMissing
            case phenophaseTooLong
            case area(String)
            case areaTooLarge(String, String)
            /// Every parcel unticked: that is withdrawing the treatment, which
            /// «Изтрий» on the journal row does (`TREATMENT_CORRECTION_WOULD_EMPTY`).
            case noParcels
            case nothingChanged

            var text: String {
                switch self {
                case .futureDate: TreatmentDraft.Problem.futureDate.text
                case .productMissing: TreatmentDraft.Problem.productMissing.text
                case .product(let sentence): sentence
                case .pestMissing: TreatmentDraft.Problem.pestMissing.text
                case .pestTooLong: "Вредителят е твърде дълъг — до \(Draft.pestMaxLength) знака."
                case .doseMissing: TreatmentDraft.Problem.doseMissing.text
                case .doseNotPositive: TreatmentDraft.Problem.doseNotPositive.text
                case .quarantineInvalid: "Карантинният срок е цяло число дни — от 0 до 365."
                case .quarantineMissing: TreatmentDraft.Problem.quarantineMissing.text
                case .phenophaseTooLong: TreatmentDraft.Problem.phenophaseTooLong.text
                case .area(let name): "Въведете площ над нула за «\(name)» или оставете полето празно."
                case .areaTooLarge(let name, let whole): "Площта на «\(name)» е по-голяма от парцела (\(whole))."
                case .noParcels:
                    "Остава поне един парцел. За да премахнете цялото мероприятие, използвайте «Изтрий» в Дневник."
                case .nothingChanged: "Няма промени за запазване."
                }
            }
        }

        /// The server's cap on `targetNote` (`CorrectDiaryTreatment`).
        static let pestMaxLength = 500

        /// Everything in the way of «Напред», first problem first, in the
        /// form's order.
        ///
        /// A field a spraying's record requires may not be emptied if it was
        /// filled. One that was never captured, on a record older than the
        /// rule, may stay empty: the correction is not the place to demand
        /// what the day did not record.
        func problems(now: Date = Date()) -> [Problem] {
            var found: [Problem] = []
            let calendar = Calendar(identifier: .gregorian)
            if calendar.startOfDay(for: date) > calendar.startOfDay(for: now) { found.append(.futureDate) }
            if TypedProduct.cleaned(productText).isEmpty {
                found.append(.productMissing)
            } else if let issue = productIssue {
                switch issue {
                case .loading:
                    found.append(.product("Каталогът на стопанството още се зарежда."))
                case .notInCatalogue:
                    found.append(.product("«\(TypedProduct.cleaned(productText))» не е в каталога на стопанството. "
                                          + "С корекция се избира продукт от каталога."))
                case .wrongKind(let name):
                    // The kind isn't corrected: a fertilising takes a fertiliser.
                    found.append(.product("«\(name)» не е тор. Изберете тор от каталога на стопанството."))
                case .sample(let name):
                    found.append(.product("«\(name)» е образцов продукт. Въведете истинското търговско наименование."))
                }
            }
            if spraying {
                if targetNote == nil, original.targetNote?.recorded != nil { found.append(.pestMissing) }
                if let note = targetNote, note.count > Self.pestMaxLength { found.append(.pestTooLong) }
            }
            if let dose {
                if dose <= 0 { found.append(.doseNotPositive) }
            } else {
                found.append(.doseMissing)
            }
            if spraying {
                if let stage = phenophase, stage.count > TreatmentDraft.phenophaseMaxLength {
                    found.append(.phenophaseTooLong)
                }
                if !quarantine.valid {
                    found.append(.quarantineInvalid)
                } else if quarantine.days == nil, original.quarantinePeriodDays != nil {
                    found.append(.quarantineMissing)
                }
            }
            if chosen.isEmpty { found.append(.noParcels) }
            if let parcel = chosenParcels.first(where: { !area(of: $0.id).valid }) {
                found.append(.area(parcel.name))
            } else if let parcel = chosenParcels.first(where: { tooLarge($0) != nil }), let own = tooLarge(parcel) {
                found.append(.areaTooLarge(parcel.name, own.text))
            }
            if found.isEmpty, changed.isEmpty { found.append(.nothingChanged) }
            return found
        }

        /// One change, as «Проверка» reads it back. Nil is a field left
        /// empty, which the screen says in words.
        struct Change: Equatable, Sendable, Identifiable {
            let id: String
            let label: String
            let before: String?
            let after: String?
        }

        var changes: [Change] {
            let fields = changed
            var out: [Change] = []
            for field in fields {
                switch field {
                case .occurredOn:
                    out.append(Change(id: field.rawValue, label: "Дата",
                                      before: original.occurredOn.flatMap(BgDate.parseISODay).map(BgDate.full),
                                      after: BgDate.full(date)))
                case .productItemId:
                    out.append(Change(id: field.rawValue, label: kind.inputLabel,
                                      before: original.productName, after: product?.name))
                case .targetNote:
                    out.append(Change(id: field.rawValue, label: "Вредител",
                                      before: original.targetNote?.recorded, after: targetNote))
                case .doseValue, .doseUnitId:
                    // One line for the two, as on the form.
                    guard !out.contains(where: { $0.id == "dose" }) else { continue }
                    out.append(Change(id: "dose", label: "Доза",
                                      before: doseLine(original.doseValue, originalUnitSymbol),
                                      after: doseLine(dose ?? original.doseValue, doseUnit.symbol)))
                case .phenophase:
                    out.append(Change(id: field.rawValue, label: "Фенофаза/BBCH",
                                      before: original.phenophase?.recorded, after: phenophase))
                case .quarantinePeriodDays:
                    out.append(Change(id: field.rawValue, label: "Карантинен срок",
                                      before: original.quarantinePeriodDays.map { Plural.bg($0, "ден", "дни") },
                                      after: quarantine.days.map { Plural.bg($0, "ден", "дни") }))
                case .applicationTechnique:
                    out.append(Change(id: field.rawValue, label: "Техника",
                                      before: ApplicationTechnique.display(original.applicationTechnique),
                                      after: ApplicationTechnique.display(technique)))
                case .parcels:
                    // In the list's order: a recorded parcel dropped or its
                    // area moved, then each one added.
                    for parcel in parcels {
                        let line = original.lines.first { $0.parcelId == parcel.id }
                        let kept = chosen.contains(parcel.id)
                        if line != nil, !kept {
                            out.append(Change(id: "drop:\(parcel.id)", label: "Премахнат парцел",
                                              before: parcel.name, after: nil))
                        } else if let line, areaChanged(line) {
                            out.append(Change(id: "area:\(parcel.id)", label: "Площ — \(parcel.name)",
                                              before: Self.areaText(line.treatedAreaHa.map(Area.init(hectares:))),
                                              after: Self.areaText(sentArea(parcel.id))))
                        } else if line == nil, kept {
                            out.append(Change(id: "add:\(parcel.id)", label: "Добавен парцел", before: nil,
                                              after: "\(parcel.name) — \(Self.areaText(sentArea(parcel.id)))"))
                        }
                    }
                }
            }
            return out
        }

        static func areaText(_ area: Area?) -> String { area?.text ?? TreatmentCorrection.wholeParcel }
    }
}

extension TreatmentCorrection {

    // MARK: - The trail

    /// «Коригирано на … в … от …» (owner, 2026-10-22). The time too, as two
    /// corrections on one day are told apart by it. The name is left out
    /// when the server can't give one, and never replaced by an id.
    static func correctedLine(_ entry: TreatmentCorrectionTrail.Entry) -> String {
        let when = "Коригирано на \(BgDate.full(entry.correctedAt)) в \(BgDate.time(entry.correctedAt))"
        guard let who = entry.correctedBy?.recorded else { return when }
        return "\(when) от \(who)"
    }

    /// One field a correction changed: its label, and what it said before.
    struct Was: Equatable, Sendable, Identifiable {
        let label: String
        /// What it said before; nil when it was empty.
        let value: String?
        /// False where the earlier value can't be shown (a rate stored
        /// without its unit's symbol, a field with no value to read), or the
        /// definition before was unreadable: then the field is named as
        /// changed, with no value.
        let shown: Bool
        var id: String { label }
    }

    /// The changed fields in the form's order, each once: the dose's value
    /// and unit are one line, as on the form, and so are the water rate's.
    /// A field this build has no name for is left out rather than shown by
    /// its server name.
    static func was(_ entry: TreatmentCorrectionTrail.Entry) -> [Was] {
        let changed = Set(entry.changedFields)
        let before = entry.previous
        func line(_ label: String, _ value: String?) -> Was {
            Was(label: label, value: value, shown: before != nil)
        }
        func named(_ label: String) -> Was { Was(label: label, value: nil, shown: false) }
        var out: [Was] = []
        if changed.contains("occurredOn") {
            out.append(line("Дата", before?.occurredOn.flatMap(BgDate.parseISODay).map(BgDate.full)))
        }
        if changed.contains("title") { out.append(named("Наименование")) }
        if changed.contains("productItemId") {
            out.append(line(before?.treatmentKind?.inputLabel ?? "Препарат", before?.productName.recorded))
        }
        if changed.contains("targetNote") { out.append(line("Вредител", before?.targetNote?.recorded)) }
        // A rate is said with its unit or not at all: «Беше: 0,15» could be
        // any unit. A `previous` stored before agri-saas #2298 has no symbol,
        // so it is only named.
        if !changed.isDisjoint(with: ["doseValue", "doseUnitId"]) {
            if let before, let symbol = before.doseUnitSymbol?.recorded {
                out.append(line("Доза", "\(Draft.doseText(before.doseValue)) \(symbol)"))
            } else {
                out.append(named("Доза"))
            }
        }
        if !changed.isDisjoint(with: ["waterRateValue", "waterRateUnitId"]) {
            if let before, before.waterRateValue == nil {
                out.append(line("Разход на работен разтвор", nil))
            } else if let before, let value = before.waterRateValue, let symbol = before.waterRateUnitSymbol?.recorded {
                out.append(line("Разход на работен разтвор", "\(Draft.doseText(value)) \(symbol)"))
            } else {
                out.append(named("Разход на работен разтвор"))
            }
        }
        if changed.contains("phenophase") { out.append(line("Фенофаза/BBCH", before?.phenophase?.recorded)) }
        if changed.contains("quarantinePeriodDays") {
            out.append(line("Карантинен срок", before?.quarantinePeriodDays.map { Plural.bg($0, "ден", "дни") }))
        }
        if changed.contains("applicationTechnique") {
            out.append(line("Техника", ApplicationTechnique.display(before?.applicationTechnique)))
        }
        if !changed.isDisjoint(with: ["parcels", "treatedAreaHa"]) {
            // Every parcel and its area as it was, from the definition's own
            // lines: the trail says what the set was, not which line moved.
            out.append(line(changed.contains("parcels") ? "Парцели" : "Третирана площ", before.map { previous in
                previous.lines
                    .map { "\($0.parcelName) — \(Draft.areaText($0.treatedAreaHa.map(Area.init(hectares:))))" }
                    .joined(separator: ", ")
            }))
        }
        return out
    }

    /// The line under a field: what it was, or only that it changed.
    static func wasText(_ was: Was) -> String {
        was.shown ? "Беше: \(was.value ?? "—")" : "Променено"
    }

    /// One correction as VoiceOver reads it: a dash is read as nothing.
    static func spoken(_ entry: TreatmentCorrectionTrail.Entry) -> String {
        let fields = was(entry).map { was in
            was.shown ? "\(was.label): беше \(was.value ?? "няма")" : "\(was.label): променено"
        }
        return ([correctedLine(entry)] + fields).joined(separator: ". ")
    }
}

extension JournalTreatment {
    /// The row as the correction left it, until the journal is read again:
    /// the entry's screen holds the row it was opened with.
    func applying(_ saved: TreatmentCorrection.Saved) -> JournalTreatment {
        let corrected = saved.definition
        var row = self
        row.productName = corrected.productName
        row.doseValue = corrected.doseValue
        row.doseUnit = saved.unitSymbol ?? row.doseUnit
        // A corrected area changes the total, which can't be worked out
        // here: a whole parcel's area isn't in the definition. Left out until
        // the journal is read again rather than shown as it was.
        if saved.areaChanged {
            row.totalAreaHa = nil
            // The set may have moved too; the blocks' names wait for the
            // journal to be read again, as the total does.
            row.parcelCount = corrected.lines.count
        }
        row.targetNote = corrected.targetNote
        row.phenophase = corrected.phenophase
        row.applicationTechnique = corrected.applicationTechnique
        row.quarantinePeriodDays = corrected.quarantinePeriodDays
        // The server's own rule (`earliestHarvestOn`): the day plus the
        // period captured, nothing without a period.
        row.earliestHarvestOn = corrected.occurredOn.flatMap(BgDate.parseISODay).flatMap { day in
            corrected.quarantinePeriodDays.flatMap { TreatmentCheck.earliestHarvest(after: day, days: $0) }
        }.map(BgDate.isoDay)
        return row
    }
}

private extension KeyedEncodingContainer {
    /// The value, or an explicit `null`: "cleared", where leaving the key
    /// out would mean "unchanged".
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
