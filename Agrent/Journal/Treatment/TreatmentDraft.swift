import Foundation

/// «Ново мероприятие», step one: the fields of one treatment, every one of
/// them required (agrent-ios#293; agri-saas #1740).
///
/// ── The ДНЕВНИК's own columns ──
///
/// The owner modelled the flow on PRZ's «Добавяне на мероприятие», and its
/// fields are the БАБХ ДНЕВНИК's: the chemical table's Дата, Вредител,
/// средство за РЗ, Доза, Техника, Карантинен срок and Най-ранна дата за
/// прибиране; the fertiliser table's Дата, Търговско наименование and
/// Употребено количество. The treated area is not typed: it is the parcels
/// chosen in step two.
///
/// ── Done work only (owner, 2026-10-13) ──
///
/// A record of a treatment that happened, so its date is today or earlier.
/// Handing work to an operator stays in Задачи.
///
/// Pure, so the rules are read by a test rather than by tapping a form.
struct TreatmentDraft: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case spray = "SPRAY"
        case fertilize = "FERTILIZE"
        var id: String { rawValue }
        var label: String { self == .spray ? "Пръскане" : "Торене" }
        /// The input's own word, as the ДНЕВНИК's two tables name it.
        var inputLabel: String { self == .spray ? "Препарат" : "Тор" }
    }

    var kind: Kind = .spray
    var date: Date
    /// The trade name, typed and matched against the farm's catalogue — see
    /// `TypedProduct`.
    var productText = ""
    /// A NEW plant protection product's ЗЗР registration number. A product
    /// the farm already has carries its own.
    var registrationText = ""
    /// Prefilled from the product's registration and editable, as PRZ's
    /// form has it. A new product's is typed here too.
    var quarantineText = ""
    /// «Вредител»: what the treatment was against, as the ДНЕВНИК prints it.
    var pestText = ""
    var doseText = ""
    var doseUnit: Unit?
    /// «Фенофаза/BBCH» (#363): the crop's growth stage on the day, optional
    /// on a spraying (owner, 2026-10-20). Free text, because the register's
    /// column takes a BBCH code or a stage name, as PRZ's field does.
    var phenophaseText = ""
    /// The treated area typed for a chosen parcel, in decares, by parcel id
    /// (#363, agri-saas #2086). Empty means the whole parcel. Here, in the
    /// draft, so a changed area is a changed entry and mints a new save key
    /// (`TreatmentAttempt`): a reused key with a changed body is replayed,
    /// not refused, so an area kept outside the draft would be lost.
    var treatedText: [String: String] = [:]
    var technique: ApplicationTechnique = .boom

    /// What the prefill put in, so a later product can replace it while the
    /// person has not touched it — and nothing they typed is ever replaced.
    private(set) var prefilledQuarantine: String?
    private(set) var prefilledUnitID: String?

    init(date: Date = Date()) { self.date = date }

    /// One thing still missing or wrong, in the order the form asks for it.
    enum Problem: Equatable, Sendable {
        case futureDate
        case productMissing
        case product(String)
        case registrationMissing
        case pestMissing
        case doseMissing
        case doseNotPositive
        case unitMissing
        case quarantineMissing
        case phenophaseTooLong

        var text: String {
            switch self {
            case .futureDate: "Датата не може да е в бъдещето — записват се извършени мероприятия."
            case .productMissing: "Въведете препарат или тор."
            case .product(let sentence): sentence
            case .registrationMissing: "За нов препарат въведете рег. № по ЗЗР."
            case .pestMissing: "Въведете вредителя."
            case .doseMissing: "Въведете дозата."
            case .doseNotPositive: "Дозата трябва да е по-голяма от нула."
            case .unitMissing: "Изберете мерна единица за дозата."
            case .quarantineMissing: "Въведете карантинния срок в дни."
            case .phenophaseTooLong: "Фенофазата е твърде дълга — до \(TreatmentDraft.phenophaseMaxLength) знака."
            }
        }
    }

    /// The typed name against the catalogue. While the catalogue is not in
    /// hand a name counts as NEW, as on the parcel sheet: its registration is
    /// asked for, and the server ignores it should it find the product.
    func typed(in catalogue: [InputItem]?) -> TypedProduct {
        guard let catalogue else {
            return TypedProduct.cleaned(productText).isEmpty ? .empty : .new
        }
        return TypedProduct.classify(productText, spraying: kind == .spray, catalogue: catalogue)
    }

    var dose: Decimal? { Self.decimal(doseText) }

    /// The treated area of each chosen parcel that ISN'T the whole parcel.
    ///
    /// An entry within the register's tolerance of the parcel's own area is
    /// the whole parcel and left out: the field shows that area rounded, and
    /// typing the shown figure back must not read as larger than the parcel,
    /// which the server refuses (`TREATMENT_AREA_EXCEEDS_PARCEL`, inclusive).
    /// A parcel with no recorded area takes any positive value.
    static func treatedAreas(_ texts: [String: String], for fields: [TreatmentPlace.Field]) -> [String: Area] {
        var areas: [String: Area] = [:]
        for field in fields {
            guard let text = texts[field.id]?.recorded, let area = Area.parse(decares: text) else { continue }
            if let whole = field.parcel.areaHa.map({ Area(hectares: $0) }), !area.differs(from: whole) { continue }
            areas[field.id] = area
        }
        return areas
    }

    /// The first chosen parcel whose typed area can't go out, in list order.
    static func treatedProblem(_ texts: [String: String], for fields: [TreatmentPlace.Field]) -> String? {
        for field in fields {
            guard let text = texts[field.id]?.recorded else { continue }
            guard let area = Area.parse(decares: text) else {
                return "Въведете площ над нула за «\(field.parcel.name)» или оставете полето празно."
            }
            if let whole = field.parcel.areaHa.map({ Area(hectares: $0) }),
               area.wireHectares > whole.wireHectares, area.differs(from: whole) {
                return "Площта на «\(field.parcel.name)» е по-голяма от парцела (\(whole.text))."
            }
        }
        return nil
    }

    /// The server's cap (`RecordDiaryTreatment.phenophase`, agri-saas #2083).
    static let phenophaseMaxLength = 64

    /// Trimmed, and nil when empty: the server stores an omitted stage as
    /// "not captured", never as a blank one.
    var phenophase: String? {
        let text = phenophaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var quarantineDays: Int? {
        guard let days = Int(quarantineText.trimmingCharacters(in: .whitespacesAndNewlines)),
              days >= 0 else { return nil }
        return days
    }

    /// «Най-ранна дата за прибиране»: the date plus the quarantine period,
    /// as the ДНЕВНИК computes it (`buildChemicalRows`). Shown, never typed.
    var earliestHarvest: Date? {
        guard kind == .spray, let days = quarantineDays else { return nil }
        return TreatmentCheck.earliestHarvest(after: date, days: days)
    }

    /// Everything still in the way of «Напред», first problem first.
    func problems(catalogue: [InputItem]?, now: Date = Date()) -> [Problem] {
        var found: [Problem] = []
        if Calendar(identifier: .gregorian).startOfDay(for: date)
            > Calendar(identifier: .gregorian).startOfDay(for: now) {
            found.append(.futureDate)
        }
        let typed = typed(in: catalogue)
        switch typed {
        case .empty:
            found.append(.productMissing)
        case .wrongKind(let item):
            found.append(.product("«\(item.name)» не е тор. Запишете го като «Пръскане»."))
        case .sample(let item):
            found.append(.product("«\(item.name)» е образцов продукт. Въведете истинското търговско наименование."))
        case .new where TypedProduct.isTooLong(productText):
            found.append(.product("Наименованието е твърде дълго — до \(TypedProduct.maxLength) знака."))
        case .new where kind == .spray
            && registrationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            found.append(.registrationMissing)
        case .new, .existing:
            break
        }
        if kind == .spray, pestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(.pestMissing)
        }
        if let dose {
            if dose <= 0 { found.append(.doseNotPositive) }
        } else {
            found.append(.doseMissing)
        }
        if doseUnit == nil { found.append(.unitMissing) }
        if kind == .spray, quarantineDays == nil { found.append(.quarantineMissing) }
        if kind == .spray, let stage = phenophase, stage.count > Self.phenophaseMaxLength {
            found.append(.phenophaseTooLong)
        }
        return found
    }

    /// The product's own quarantine period and dose unit — PRZ's prefill.
    ///
    /// Into a field the person has not touched: empty, or still holding what
    /// the last prefill put there. So «Карате» on the way to «Карате Зеон 5
    /// CS» does not leave the first product's period behind for the second —
    /// a wrong period is a wrong «Най-ранна дата за прибиране» on a legal
    /// register — and a name that stops matching any product takes the
    /// prefill away again. What was typed is never replaced.
    ///
    /// The unit is taken from `units` (`/units`), never `/items`' own copy,
    /// which has no name and would not match the picker's tags.
    mutating func prefill(from typed: TypedProduct, units: [Unit]) {
        let item: InputItem? = if case .existing(let found) = typed { found } else { nil }
        if quarantineText.isEmpty || quarantineText == prefilledQuarantine {
            let days = item?.quarantinePeriodDays.map(String.init)
            quarantineText = days ?? ""
            prefilledQuarantine = days
        }
        if doseUnit == nil || (doseUnit?.id).map({ $0 == prefilledUnitID }) == true {
            let unit = item?.defaultUnit.flatMap { wanted in units.first { $0.id == wanted.id } }
            doseUnit = unit
            prefilledUnitID = unit?.id
        }
    }

    /// Comma or point, spaces ignored — the parcel sheet's rule.
    static func decimal(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: WireDecimal.wireLocale)
    }
}

extension Dictionary where Key == String, Value == String {
    /// A field's typed text by id, for a binding: a key path can't carry
    /// `[key, default: ""]`, whose default is a closure (see `AppRouter`).
    /// Clearing the field removes the entry, so "whole parcel" is no entry.
    subscript(typed key: String) -> String {
        get { self[key] ?? "" }
        set { self[key] = newValue.isEmpty ? nil : newValue }
    }
}
