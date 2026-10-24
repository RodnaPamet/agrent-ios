import Foundation

/// «Коригирай» on a recorded treatment (agrent-ios #392; owner 2026-10-24):
/// who is offered it, what the form holds, and what goes out.
///
/// Pure, so the rules are read by a test rather than by tapping a form. The
/// API is `TreatmentCorrectionAPI`; the screens are `TreatmentCorrectionFlow`.
enum TreatmentCorrection {

    /// The journal row's own answer, never a probe of the write-gated GET.
    ///
    /// The server's rule for a correction is the withdrawal's: creator or
    /// administrator, and one author across the treatment's tasks (agri-saas
    /// #2283). The row's `mayDelete` is computed from that rule, so it stands
    /// in until the row carries a flag of its own. That is asked for, because
    /// agri-saas #2280 may narrow the withdrawal again and the two would then
    /// differ. The route checks again either way, and its refusal is read out.
    nonisolated static func offered(_ entry: LogEntry, to me: CurrentUser?) -> Bool {
        TreatmentRemoval.offered(entry, to: me)
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

    /// The server's sentence, except where its wording is about deleting.
    ///
    /// `TREATMENT_MIXED_AUTHORSHIP` is shared with the withdrawal, and its
    /// text says the treatment can't be REMOVED, which is not what was asked
    /// here. A correction is refused for administrators too, so it doesn't
    /// send anyone to one.
    static func text(for error: Error) -> String {
        if case APIClient.APIError.http(_, "TREATMENT_MIXED_AUTHORSHIP", _, _, _) = error {
            return "Това мероприятие е записано от повече от един човек, затова не може да се коригира."
        }
        return UserMessage.text(for: error)
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
