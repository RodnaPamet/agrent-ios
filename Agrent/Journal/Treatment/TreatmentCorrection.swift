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
        guard let treatment = entry.treatment, treatment.isTreatment,
              treatment.treatmentGroupId != nil,
              let me, me.mayWrite else { return false }
        return treatment.mayCorrect ?? true
    }

    static let actionTitle = "Коригирай"

    /// What can't be corrected yet, said where it is shown locked.
    static func lockedNote(_ kind: TreatmentDraft.Kind) -> String {
        "\(kind == .fertilize ? "Торът" : "Препаратът"), дозата и парцелите не могат да се коригират все още."
    }

    /// Someone else corrected it after the form was opened (409 `STALE_DATA`).
    /// Their correction stands; this one would have overwritten it unseen.
    static let staleText =
        "Някой друг е коригирал мероприятието междувременно. Заредете го отново, "
        + "за да видите сегашните стойности. Вашите промени няма да бъдат запазени."
    static let reloadTitle = "Зареди отново"

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
    /// The product, dose and parcels are never sent: the form can't change
    /// them, and an unchanged one would only be compared and ignored.
    struct Body: Encodable, Equatable, Sendable {
        enum Field: String, CodingKey, CaseIterable, Sendable {
            case occurredOn, targetNote, phenophase, quarantinePeriodDays, applicationTechnique
        }

        let fields: Set<Field>
        let occurredOn: String
        let targetNote: String?
        let phenophase: String?
        let quarantinePeriodDays: Int?
        let applicationTechnique: String?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            for field in Field.allCases where fields.contains(field) {
                switch field {
                case .occurredOn: try c.encode(occurredOn, forKey: field)
                case .targetNote: try c.encodeOrNull(targetNote, forKey: field)
                case .phenophase: try c.encodeOrNull(phenophase, forKey: field)
                case .quarantinePeriodDays: try c.encodeOrNull(quarantinePeriodDays, forKey: field)
                case .applicationTechnique: try c.encodeOrNull(applicationTechnique, forKey: field)
                }
            }
        }
    }

    // MARK: - The form

    /// The form's fields, started from the definition as recorded.
    struct Draft: Equatable, Sendable {
        let original: TreatmentDefinition
        var date: Date
        var pestText: String
        var phenophaseText: String
        var quarantineText: String
        /// A slug (`ApplicationTechnique`), or a stored value outside the
        /// seven, kept as it is. Nil when none was recorded.
        var technique: String?

        init(_ definition: TreatmentDefinition, today: Date = Date()) {
            original = definition
            date = definition.occurredOn.flatMap(BgDate.parseISODay) ?? today
            pestText = definition.targetNote ?? ""
            phenophaseText = definition.phenophase ?? ""
            quarantineText = definition.quarantinePeriodDays.map(String.init) ?? ""
            technique = Self.slug(definition.applicationTechnique)
        }

        var kind: TreatmentDraft.Kind { original.treatmentKind ?? .spray }

        /// The fields only a spraying has, as on «Ново мероприятие».
        var spraying: Bool { kind == .spray }

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

        /// What differs from the record, in the form's order.
        var changed: [Body.Field] {
            var out: [Body.Field] = []
            if day != original.occurredOn { out.append(.occurredOn) }
            guard spraying else { return out }
            if targetNote != original.targetNote?.recorded { out.append(.targetNote) }
            if phenophase != original.phenophase?.recorded { out.append(.phenophase) }
            if quarantine.valid, quarantine.days != original.quarantinePeriodDays {
                out.append(.quarantinePeriodDays)
            }
            if technique != Self.slug(original.applicationTechnique) { out.append(.applicationTechnique) }
            return out
        }

        var body: Body {
            Body(fields: Set(changed), occurredOn: day, targetNote: targetNote, phenophase: phenophase,
                 quarantinePeriodDays: quarantine.days, applicationTechnique: technique)
        }

        enum Problem: Equatable, Sendable {
            case futureDate
            case pestMissing
            case pestTooLong
            case quarantineInvalid
            case quarantineMissing
            case phenophaseTooLong
            case nothingChanged

            var text: String {
                switch self {
                case .futureDate: TreatmentDraft.Problem.futureDate.text
                case .pestMissing: TreatmentDraft.Problem.pestMissing.text
                case .pestTooLong: "Вредителят е твърде дълъг — до \(Draft.pestMaxLength) знака."
                case .quarantineInvalid: "Карантинният срок е цяло число дни — от 0 до 365."
                case .quarantineMissing: TreatmentDraft.Problem.quarantineMissing.text
                case .phenophaseTooLong: TreatmentDraft.Problem.phenophaseTooLong.text
                case .nothingChanged: "Няма промени за запазване."
                }
            }
        }

        /// The server's cap on `targetNote` (`CorrectDiaryTreatment`).
        static let pestMaxLength = 500

        /// Everything in the way of «Напред», first problem first.
        ///
        /// A field a spraying's record requires may not be emptied if it was
        /// filled. One that was never captured, on a record older than the
        /// rule, may stay empty: the correction is not the place to demand
        /// what the day did not record.
        func problems(now: Date = Date()) -> [Problem] {
            var found: [Problem] = []
            let calendar = Calendar(identifier: .gregorian)
            if calendar.startOfDay(for: date) > calendar.startOfDay(for: now) { found.append(.futureDate) }
            if spraying {
                if targetNote == nil, original.targetNote?.recorded != nil { found.append(.pestMissing) }
                if let note = targetNote, note.count > Self.pestMaxLength { found.append(.pestTooLong) }
                if let stage = phenophase, stage.count > TreatmentDraft.phenophaseMaxLength {
                    found.append(.phenophaseTooLong)
                }
                if !quarantine.valid {
                    found.append(.quarantineInvalid)
                } else if quarantine.days == nil, original.quarantinePeriodDays != nil {
                    found.append(.quarantineMissing)
                }
            }
            if found.isEmpty, changed.isEmpty { found.append(.nothingChanged) }
            return found
        }

        /// One changed field, as «Проверка» reads it back. Nil is a field
        /// left empty, which the screen says in words.
        struct Change: Equatable, Sendable, Identifiable {
            let field: Body.Field
            let label: String
            let before: String?
            let after: String?
            var id: Body.Field { field }
        }

        var changes: [Change] {
            changed.map { field in
                switch field {
                case .occurredOn:
                    Change(field: field, label: "Дата",
                           before: original.occurredOn.flatMap(BgDate.parseISODay).map(BgDate.full),
                           after: BgDate.full(date))
                case .targetNote:
                    Change(field: field, label: "Вредител", before: original.targetNote?.recorded, after: targetNote)
                case .phenophase:
                    Change(field: field, label: "Фенофаза/BBCH", before: original.phenophase?.recorded, after: phenophase)
                case .quarantinePeriodDays:
                    Change(field: field, label: "Карантинен срок",
                           before: original.quarantinePeriodDays.map { Plural.bg($0, "ден", "дни") },
                           after: quarantine.days.map { Plural.bg($0, "ден", "дни") })
                case .applicationTechnique:
                    Change(field: field, label: "Техника",
                           before: ApplicationTechnique.display(original.applicationTechnique),
                           after: ApplicationTechnique.display(technique))
                }
            }
        }
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
        /// False where this build can't show the earlier value (the dose,
        /// whose unit the definition names by id), or the definition before
        /// was unreadable: then the field is named as changed, with no value.
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
        if !changed.isDisjoint(with: ["doseValue", "doseUnitId"]) { out.append(named("Доза")) }
        if !changed.isDisjoint(with: ["waterRateValue", "waterRateUnitId"]) {
            out.append(named("Разход на работен разтвор"))
        }
        if changed.contains("phenophase") { out.append(line("Фенофаза/BBCH", before?.phenophase?.recorded)) }
        if changed.contains("quarantinePeriodDays") {
            out.append(line("Карантинен срок", before?.quarantinePeriodDays.map { Plural.bg($0, "ден", "дни") }))
        }
        if changed.contains("applicationTechnique") {
            out.append(line("Техника", ApplicationTechnique.display(before?.applicationTechnique)))
        }
        if !changed.isDisjoint(with: ["parcels", "treatedAreaHa"]) { out.append(named("Третирана площ")) }
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
    func applying(_ corrected: TreatmentDefinition) -> JournalTreatment {
        var row = self
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
