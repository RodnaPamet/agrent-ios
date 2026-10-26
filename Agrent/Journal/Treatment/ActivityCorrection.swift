import Foundation

/// «Коригирай» on pruning, cultivation or a harvest (#439; agri-saas #2375):
/// who is offered it, what the form holds, and what goes out.
///
/// The treatment correction's shape (`TreatmentCorrection`) with fewer
/// fields: the day, a harvest's total, and the parcels (#447). Pure, so the rules are read by a test
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

    /// What a save hands the entry's screen: the corrected activity, and
    /// whether its parcels moved, which decides whether the row's total area
    /// and block names still hold.
    struct Saved: Equatable, Sendable {
        let definition: ActivityDefinition
        var parcelsChanged = false
    }

    // MARK: - The body

    /// `PUT …/definition` (`CorrectFarmActivity`), carrying only what the
    /// person changed: an omitted field is left as it is. A harvest's total
    /// would go out as `null` to clear it, which the server allows; the form
    /// never asks that, as a harvest is recorded with its total (owner,
    /// 2026-10-25), so a cleared field is a problem instead.
    ///
    /// The parcels go out as the WHOLE corrected set (`parcelIds`), never a
    /// delta, with `parcels[]` giving each one's area in hectares
    /// (agri-saas #2386). A retained parcel left out of `parcels[]` is the
    /// whole parcel to the server, which compares areas exactly; so a stored
    /// area that wasn't touched goes back to the digit, never read back from
    /// the decares the field shows, and a whole parcel as its own exact area
    /// (owner, 2026-10-25), left out only where that isn't known.
    struct Body: Encodable, Equatable, Sendable {
        enum Field: String, CaseIterable, Sendable {
            case occurredOn, harvestKg, parcels
        }

        struct ParcelArea: Encodable, Equatable, Sendable {
            let parcelId: String
            /// Hectares, over zero: the key is required, so the whole parcel
            /// is its exact area, and one of unknown area is left out.
            let treatedAreaHa: Double
        }

        let fields: Set<Field>
        let occurredOn: String
        let harvestKg: Decimal?
        var parcelIds: [String] = []
        var parcels: [ParcelArea] = []

        private enum Key: String, CodingKey { case occurredOn, harvestKg, parcelIds, parcels }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            if fields.contains(.occurredOn) { try c.encode(occurredOn, forKey: .occurredOn) }
            if fields.contains(.harvestKg) {
                if let harvestKg { try c.encode(harvestKg, forKey: .harvestKg) } else { try c.encodeNil(forKey: .harvestKg) }
            }
            if fields.contains(.parcels) {
                try c.encode(parcelIds, forKey: .parcelIds)
                if !parcels.isEmpty { try c.encode(parcels, forKey: .parcels) }
            }
        }
    }

    // MARK: - The form

    struct Draft: Equatable, Sendable {
        let original: ActivityDefinition
        var date: Date
        /// The harvest's total as typed, in kg. Unused on other work.
        var harvestText: String
        /// Each parcel's area as typed, in decares, by parcel id. Empty is
        /// the whole parcel.
        var areaTexts: [String: String]
        /// The activity's parcels as recorded, then the other parcels of the
        /// blocks read (`offer`), each block's together.
        private(set) var parcels: [TreatmentCorrection.Draft.ParcelChoice]
        /// The parcels ticked: the whole set the correction keeps.
        var chosen: Set<String>

        init(_ definition: ActivityDefinition, today: Date = Date()) {
            original = definition
            date = definition.occurredOn.flatMap(BgDate.parseISODay) ?? today
            harvestText = definition.harvestKg.map(TreatmentCorrection.Draft.doseText) ?? ""
            var areas: [String: String] = [:]
            for line in definition.lines {
                areas[line.parcelId] = line.treatedAreaHa.map { Area(hectares: $0).number } ?? ""
            }
            areaTexts = areas
            parcels = definition.lines.map {
                .init(id: $0.parcelId, name: $0.parcelName?.recorded ?? "Парцел", blockID: $0.locationId ?? "",
                      areaHa: nil, recorded: true)
            }
            chosen = Set(definition.lines.map(\.parcelId))
        }

        var activity: ActivityKind? { original.activity }
        var isHarvest: Bool { activity == .harvest }
        var day: String { BgDate.isoDay(date) }

        /// The total typed, nil when the field is empty or isn't a number.
        var harvestKg: Decimal? { TreatmentDraft.decimal(harvestText) }

        // MARK: The parcels

        /// The blocks the recorded parcels are in, in the order they first
        /// appear: read first, as the list's opening sections.
        var blockIDs: [String] {
            var seen = Set<String>()
            return original.lines.compactMap { $0.locationId?.recorded }.filter { seen.insert($0).inserted }
        }

        /// Blocks read: each recorded parcel's own area filled in, and each
        /// block's other parcels offered after the recorded ones, unticked,
        /// block by block. Any block may be offered (owner, 2026-10-26).
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
                    parcels.append(.init(id: parcel.id, name: parcel.name, blockID: block.id,
                                         areaHa: parcel.areaHa, recorded: false))
                }
            }
        }

        /// The ticked parcels, in the list's order.
        var chosenParcels: [TreatmentCorrection.Draft.ParcelChoice] { parcels.filter { chosen.contains($0.id) } }

        /// A parcel's typed area: nil for the whole parcel, and not valid
        /// when it isn't an area over zero.
        func area(of id: String) -> (valid: Bool, area: Area?) {
            guard let text = areaTexts[id]?.recorded else { return (true, nil) }
            guard let area = Area.parse(decares: text), area.wireHectares > 0 else { return (false, nil) }
            return (true, area)
        }

        /// The area typed, or nil for the whole parcel, which is also what a
        /// typed area within the register's rounding of the parcel's own is.
        func sentArea(_ id: String) -> Area? {
            guard let typed = area(of: id).area else { return nil }
            if let own = parcels.first(where: { $0.id == id })?.areaHa.map(Area.init(hectares:)),
               !typed.differs(from: own) { return nil }
            return typed
        }

        /// Larger than the parcel, by more than the register rounds: the
        /// server refuses it (`TREATMENT_AREA_EXCEEDS_PARCEL`).
        private func tooLarge(_ parcel: TreatmentCorrection.Draft.ParcelChoice) -> Area? {
            guard let typed = area(of: parcel.id).area, let own = parcel.areaHa.map(Area.init(hectares:)),
                  typed.wireHectares > own.wireHectares, typed.differs(from: own) else { return nil }
            return own
        }

        private var setChanged: Bool { chosen != Set(original.lines.map(\.parcelId)) }

        /// A kept parcel whose area moved, by more than the field rounds.
        private func areaChanged(_ line: ActivityDefinition.Line) -> Bool {
            guard chosen.contains(line.parcelId), area(of: line.parcelId).valid else { return false }
            switch (sentArea(line.parcelId), line.treatedAreaHa.map(Area.init(hectares:))) {
            case (nil, nil): return false
            case let (now?, was?): return now.differs(from: was)
            // A whole parcel recorded as its exact area (#435), left whole.
            case (nil, let was?):
                guard let own = parcels.first(where: { $0.id == line.parcelId })?.areaHa else { return true }
                return was.differs(from: Area(hectares: own))
            default: return true
            }
        }

        /// What one chosen parcel's area goes out as, in hectares; nil to
        /// leave it out, which is the whole parcel. A stored area that wasn't
        /// touched goes back as stored (#449, as on a treatment).
        private func wireArea(_ parcel: TreatmentCorrection.Draft.ParcelChoice) -> Double? {
            if let line = original.lines.first(where: { $0.parcelId == parcel.id }), !areaChanged(line),
               let stored = line.treatedAreaHa {
                return stored
            }
            // Typed, or the whole parcel as its own exact area (owner,
            // 2026-10-25, #435); left out only where that isn't known.
            return sentArea(parcel.id)?.wireHectares ?? parcel.areaHa.flatMap { $0 > 0 ? $0 : nil }
        }

        enum Problem: Equatable, Sendable {
            case futureDate
            case harvestMissing
            case harvestNotPositive
            case noParcels
            case area(String)
            case areaTooLarge(String, String)
            case nothingChanged

            var text: String {
                switch self {
                case .futureDate: TreatmentDraft.Problem.futureDate.text
                case .harvestMissing: TreatmentDraft.Problem.harvestMissing.text
                case .harvestNotPositive: "Количеството трябва да е число над нула."
                case .noParcels: TreatmentCorrection.Draft.Problem.noParcels.text
                case .area(let name): TreatmentCorrection.Draft.Problem.area(name).text
                case .areaTooLarge(let name, let whole): TreatmentCorrection.Draft.Problem.areaTooLarge(name, whole).text
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
            // Every parcel unticked is withdrawing the activity, which
            // «Изтрий» does (`ACTIVITY_CORRECTION_WOULD_EMPTY`). A definition
            // read with no lines has nothing to untick, and its day can
            // still be corrected.
            if chosen.isEmpty, !original.lines.isEmpty { found.append(.noParcels) }
            if let parcel = chosenParcels.first(where: { !area(of: $0.id).valid }) {
                found.append(.area(parcel.name))
            } else if let parcel = chosenParcels.first(where: { tooLarge($0) != nil }), let own = tooLarge(parcel) {
                found.append(.areaTooLarge(parcel.name, own.text))
            }
            if found.isEmpty, changed.isEmpty { found.append(.nothingChanged) }
            return found
        }

        /// What differs from the record.
        var changed: [Body.Field] {
            var out: [Body.Field] = []
            if day != original.occurredOn { out.append(.occurredOn) }
            if isHarvest, let kg = harvestKg, kg > 0, kg != original.harvestKg { out.append(.harvestKg) }
            if setChanged || original.lines.contains(where: areaChanged) { out.append(.parcels) }
            return out
        }

        var body: Body {
            let chosen = chosenParcels
            return Body(fields: Set(changed), occurredOn: day, harvestKg: harvestKg,
                        parcelIds: chosen.map(\.id),
                        parcels: chosen.compactMap { parcel in
                            wireArea(parcel).map { Body.ParcelArea(parcelId: parcel.id, treatedAreaHa: $0) }
                        })
        }

        /// Each change as «Проверка» reads it back, in `Change`'s words.
        var changes: [TreatmentCorrection.Draft.Change] {
            typealias Change = TreatmentCorrection.Draft.Change
            var out: [Change] = []
            for field in changed {
                switch field {
                case .occurredOn:
                    out.append(Change(id: field.rawValue, label: "Дата",
                                      before: original.occurredOn.flatMap(BgDate.parseISODay).map(BgDate.full),
                                      after: BgDate.full(date)))
                case .harvestKg:
                    out.append(Change(id: field.rawValue, label: ActivityCorrection.harvestLabel,
                                      before: original.harvestKg.map(TreatmentCheckView.kgText),
                                      after: harvestKg.map(TreatmentCheckView.kgText)))
                case .parcels:
                    // In the list's order, as on a treatment: a recorded
                    // parcel dropped or its area moved, then each one added.
                    for parcel in parcels {
                        let line = original.lines.first { $0.parcelId == parcel.id }
                        let kept = chosen.contains(parcel.id)
                        if line != nil, !kept {
                            out.append(Change(id: "drop:\(parcel.id)", label: "Премахнат парцел",
                                              before: parcel.name, after: nil))
                        } else if let line, areaChanged(line) {
                            out.append(Change(id: "area:\(parcel.id)", label: "Площ — \(parcel.name)",
                                              before: Self.areaText(line.treatedAreaHa),
                                              after: Self.areaText(wireArea(parcel))))
                        } else if line == nil, kept {
                            out.append(Change(id: "add:\(parcel.id)", label: "Добавен парцел", before: nil,
                                              after: "\(parcel.name) — \(Self.areaText(wireArea(parcel)))"))
                        }
                    }
                }
            }
            return out
        }

        /// An area in hectares as the list shows it, or «Целият парцел».
        static func areaText(_ hectares: Double?) -> String {
            TreatmentCorrection.Draft.areaText(hectares.map(Area.init(hectares:)))
        }
    }

    /// The total's name, on «Проверка», the trail and the entry's facts, as
    /// «Нов запис»'s check names it.
    static let harvestLabel = "Прибрано"
}

extension JournalTreatment {
    /// Pruning, cultivation or a harvest, when the row is one.
    var activityKind: ActivityKind? { kind.flatMap(ActivityKind.init(rawValue:)) }

    /// The row as an activity's correction left it, until the journal is
    /// read again. A parcel change moves the total area, which can't be
    /// worked out here (a whole parcel's area isn't in the definition), so it
    /// is left out rather than shown as it was.
    func applying(_ saved: ActivityCorrection.Saved) -> JournalTreatment {
        guard saved.parcelsChanged else { return self }
        var row = self
        row.totalAreaHa = nil
        row.parcelCount = saved.definition.lines.count
        return row
    }
}
