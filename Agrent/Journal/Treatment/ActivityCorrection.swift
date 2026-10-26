import Foundation

/// «Коригирай» on pruning, cultivation or a harvest (#439; agri-saas #2375):
/// who is offered it, what the form holds, and what goes out.
///
/// The treatment correction's shape (`TreatmentCorrection`) with two fields:
/// the day, and a harvest's total. Pure, so the rules are read by a test
/// rather than by tapping a form. The API is `ActivityCorrectionAPI`; the
/// screens are `ActivityCorrectionFlow`.
enum ActivityCorrection {

    /// The row's `mayCorrect`, as for a treatment, on a row whose kind is
    /// bare work. The two offers never meet: `TreatmentCorrection.offered`
    /// takes only applications, this only the three kinds the activities'
    /// route corrects, and the kind picks the route (`NOT_A_TREATMENT` one
    /// way, `NOT_AN_ACTIVITY` the other).
    ///
    /// The server said `mayCorrect: true` on these rows before it had a route
    /// to take the correction (agri-saas #2373), which is why the kind is
    /// checked here and not left to the flag. Only an explicit `false` hides
    /// it, as on a treatment.
    nonisolated static func offered(_ entry: LogEntry, to me: CurrentUser?) -> Bool {
        guard let row = entry.treatment, row.isTreatment, row.activityKind != nil,
              row.treatmentGroupId != nil,
              let me, me.mayWrite else { return false }
        return row.mayCorrect ?? true
    }

    /// What a save hands the entry's screen: the corrected activity.
    struct Saved: Equatable, Sendable {
        let definition: ActivityDefinition
    }

    // MARK: - The body

    /// `PUT …/definition` (`CorrectFarmActivity`), carrying only what the
    /// person changed: an omitted field is left as it is. A harvest's total
    /// would go out as `null` to clear it, which the server allows; the form
    /// never asks that, as a harvest is recorded with its total (owner,
    /// 2026-10-25), so a cleared field is a problem instead.
    struct Body: Encodable, Equatable, Sendable {
        enum Field: String, CodingKey, CaseIterable, Sendable {
            case occurredOn, harvestKg
        }

        let fields: Set<Field>
        let occurredOn: String
        let harvestKg: Decimal?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            for field in Field.allCases where fields.contains(field) {
                switch field {
                case .occurredOn: try c.encode(occurredOn, forKey: field)
                case .harvestKg:
                    if let harvestKg { try c.encode(harvestKg, forKey: field) } else { try c.encodeNil(forKey: field) }
                }
            }
        }
    }

    // MARK: - The form

    struct Draft: Equatable, Sendable {
        let original: ActivityDefinition
        var date: Date
        /// The harvest's total as typed, in kg. Unused on other work.
        var harvestText: String

        init(_ definition: ActivityDefinition, today: Date = Date()) {
            original = definition
            date = definition.occurredOn.flatMap(BgDate.parseISODay) ?? today
            harvestText = definition.harvestKg.map(TreatmentCorrection.Draft.doseText) ?? ""
        }

        var activity: ActivityKind? { original.activity }
        var isHarvest: Bool { activity == .harvest }
        var day: String { BgDate.isoDay(date) }

        /// The total typed, nil when the field is empty or isn't a number.
        var harvestKg: Decimal? { TreatmentDraft.decimal(harvestText) }

        enum Problem: Equatable, Sendable {
            case futureDate
            case harvestMissing
            case harvestNotPositive
            case nothingChanged

            var text: String {
                switch self {
                case .futureDate: TreatmentDraft.Problem.futureDate.text
                case .harvestMissing: TreatmentDraft.Problem.harvestMissing.text
                case .harvestNotPositive: "Количеството трябва да е число над нула."
                case .nothingChanged: TreatmentCorrection.Draft.Problem.nothingChanged.text
                }
            }
        }

        /// Everything in the way of «Напред», first problem first.
        ///
        /// A harvest's total may not be emptied once recorded. One recorded
        /// without a total, from before the rule, may stay so: the correction
        /// is not the place to demand what the day did not record.
        func problems(now: Date = Date()) -> [Problem] {
            var found: [Problem] = []
            let calendar = Calendar(identifier: .gregorian)
            if calendar.startOfDay(for: date) > calendar.startOfDay(for: now) { found.append(.futureDate) }
            if isHarvest {
                if harvestText.recorded == nil {
                    if original.harvestKg != nil { found.append(.harvestMissing) }
                } else if harvestKg.map({ $0 <= 0 }) ?? true {
                    found.append(.harvestNotPositive)
                }
            }
            if found.isEmpty, changed.isEmpty { found.append(.nothingChanged) }
            return found
        }

        /// What differs from the record.
        var changed: [Body.Field] {
            var out: [Body.Field] = []
            if day != original.occurredOn { out.append(.occurredOn) }
            if isHarvest, let kg = harvestKg, kg > 0, kg != original.harvestKg { out.append(.harvestKg) }
            return out
        }

        var body: Body {
            Body(fields: Set(changed), occurredOn: day, harvestKg: harvestKg)
        }

        /// Each change as «Проверка» reads it back, in `Change`'s words.
        var changes: [TreatmentCorrection.Draft.Change] {
            changed.map { field in
                switch field {
                case .occurredOn:
                    TreatmentCorrection.Draft.Change(
                        id: field.rawValue, label: "Дата",
                        before: original.occurredOn.flatMap(BgDate.parseISODay).map(BgDate.full),
                        after: BgDate.full(date))
                case .harvestKg:
                    TreatmentCorrection.Draft.Change(
                        id: field.rawValue, label: ActivityCorrection.harvestLabel,
                        before: original.harvestKg.map(TreatmentCheckView.kgText),
                        after: harvestKg.map(TreatmentCheckView.kgText))
                }
            }
        }
    }

    /// The total's name, on «Проверка», the trail and the entry's facts, as
    /// «Нов запис»'s check names it.
    static let harvestLabel = "Прибрано"
}

extension JournalTreatment {
    /// Pruning, cultivation or a harvest, when the row is one.
    var activityKind: ActivityKind? { kind.flatMap(ActivityKind.init(rawValue:)) }
}
