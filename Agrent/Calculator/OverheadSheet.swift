import Foundation

/// The «Общи» half of «Нов разход» (#245): a year's overheads — salaries,
/// credit, amortisation, other — each spread over the WHOLE farm by area.
///
/// Owner, 2026-10-09: «salaries … per annum, with optional number of persons
/// and their per annum salary as well (or altogether). then allocate the
/// salary per dca of the whole farm, not only over a given crop decares»;
/// defaults are the farm's own last values; amortisation is prefilled from the
/// machinery register and may be typed over. Pure, so the rules are tests and
/// the sheet only draws them.
struct OverheadSheet: Equatable {
    /// One yearly amount as its field holds it, and when the figure it was
    /// prefilled with was last entered — said beside it, since last season's
    /// figure prefilled silently would read as this year's.
    struct Line: Equatable {
        var amountText = ""
        var lastEnteredOn: Date?
        /// The figure as the farm entered it, in leva, when the prefill
        /// converted it to the sheet's euros at the fixed rate. Said beside
        /// the field, since a converted figure is not one anybody typed.
        var convertedFromLeva: Decimal?
    }

    enum PayrollMode: Equatable, Sendable { case total, perPerson }

    var payrollMode: PayrollMode = .total
    /// The payroll TOTAL — in per-person mode it follows people × salary until
    /// typed over (`payrollTotalEdited`).
    var payroll = Line()
    var headcountText = ""
    var perPersonText = ""
    /// The farmer typed the total while it followed the product: from then on
    /// it is theirs. A hire who started in May makes a true total that does
    /// not match people × salary, and the server takes `amount` as written
    /// (agri-saas #1518) — the pair is an input aid, not a constraint.
    var payrollTotalEdited = false
    var credit = Line()
    var depreciation = Line()
    var other = Line()
    /// What «Друго» was — the line's description.
    var otherNote = ""

    // MARK: - Reading the fields

    /// The amount a field holds: spaces dropped, either decimal mark — a
    /// Bulgarian keyboard types «12 000,50» and the wire wants 12000.5. nil
    /// for nothing typed AND for something unreadable; `problems` tells them
    /// apart.
    static func amount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: WireDecimal.wireLocale)
    }

    /// A figure as the farmer would type it — the comma, no grouping.
    static func fieldText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue.replacingOccurrences(of: ".", with: ",")
    }

    var headcount: Int? {
        Int(headcountText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
    }

    var perPerson: Decimal? {
        Self.amount(perPersonText).flatMap { $0 > 0 ? $0 : nil }
    }

    /// People × yearly salary, when both are there.
    var payrollProduct: Decimal? {
        guard let headcount, let perPerson else { return nil }
        return Decimal(headcount) * perPerson
    }

    /// People or salary changed: the total follows, unless it is the farmer's.
    mutating func peopleChanged() {
        guard payrollMode == .perPerson, !payrollTotalEdited, let product = payrollProduct else { return }
        payroll.amountText = Self.fieldText(product)
    }

    // MARK: - Prefill

    /// The farm's last values, each with its date. A line with no history is
    /// left empty rather than set to zero — `nil` is «no history», and a zero
    /// would be a figure nobody typed. Salaries come back as people × salary
    /// when that is how they were entered, with the total marked as the
    /// farmer's if it did not match the product.
    ///
    /// Only a line still EMPTY is filled: the defaults arrive after the sheet
    /// opens, and a figure typed meanwhile is the farmer's.
    ///
    /// ── In the sheet's currency, or not at all ──
    ///
    /// Costs default to EUR (owner, 2026-10-10), and the farm's last values
    /// may be in leva. A leva figure is converted at the changeover's fixed
    /// rate (`EuroChangeover`) and says so; one in any other currency is left
    /// out. Under the wrong currency it would be a figure off by a factor,
    /// prefilled as if it were right.
    mutating func prefill(from defaults: OverheadDefaults, currency: String) {
        if let last = defaults.line(.payroll), payroll.amountText.isEmpty,
           headcountText.isEmpty, perPersonText.isEmpty,
           let total = EuroChangeover.convert(last.amount.value, from: last.currency, to: currency) {
            payroll = Line(amountText: Self.fieldText(total), lastEnteredOn: last.incurredOn,
                           convertedFromLeva: Self.levaOrNil(last.amount.value, from: last.currency, to: currency))
            if let people = last.payrollHeadcount, let each = last.payrollAnnualPerPerson,
               let perPerson = EuroChangeover.convert(each.value, from: last.currency, to: currency) {
                payrollMode = .perPerson
                headcountText = String(people)
                perPersonText = Self.fieldText(perPerson)
                // Compared as entered: the cents a conversion rounds are not
                // the farmer typing over the product.
                payrollTotalEdited = Decimal(people) * each.value != last.amount.value
            }
        }
        let others: [(CostCategory, WritableKeyPath<OverheadSheet, Line>)] =
            [(.credit, \.credit), (.depreciation, \.depreciation), (.other, \.other)]
        for (category, keyPath) in others where self[keyPath: keyPath].amountText.isEmpty {
            if let last = defaults.line(category),
               let amount = EuroChangeover.convert(last.amount.value, from: last.currency, to: currency) {
                self[keyPath: keyPath] = Line(amountText: Self.fieldText(amount), lastEnteredOn: last.incurredOn,
                                              convertedFromLeva: Self.levaOrNil(last.amount.value, from: last.currency, to: currency))
            }
        }
    }

    /// The register's figure into «Амортизация» — the owner's «both»: the
    /// register's figure, and the farmer types over it. Called for the field
    /// when it is empty (no history of the farm's own), and by «Използвай»
    /// when the farmer takes it over a figure they had.
    mutating func useRegister(_ figure: Decimal?, onlyIfEmpty: Bool) {
        guard let figure, figure > 0, !onlyIfEmpty || depreciation.amountText.isEmpty else { return }
        depreciation = Line(amountText: Self.fieldText(figure), lastEnteredOn: nil)
    }

    /// The leva figure behind a converted prefill, for the note; nil when
    /// nothing was converted.
    static func levaOrNil(_ amount: Decimal, from currency: String, to target: String) -> Decimal? {
        currency.uppercased() == target.uppercased() ? nil : amount
    }

    // MARK: - What goes out

    /// The lines that have something typed, in the sheet's order.
    var entered: [CostCategory] {
        [(CostCategory.payroll, payroll), (.credit, credit), (.depreciation, depreciation), (.other, other)]
            .filter { !$0.1.amountText.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.0)
    }

    private func line(_ category: CostCategory) -> Line {
        switch category {
        case .payroll: payroll
        case .credit: credit
        case .depreciation: depreciation
        default: other
        }
    }

    /// One draft per line with a readable amount: the whole farm by area
    /// (`HOLDING`), and the salary's people × salary only when both are there
    /// — both or neither, PAYROLL only (agri-saas #1518).
    func drafts(currency: String, incurredOn: String) -> [CreateCostEntry] {
        entered.compactMap { category in
            guard let amount = Self.amount(line(category).amountText) else { return nil }
            var draft = CreateCostEntry(
                category: category, amount: amount, currency: currency,
                incurredOn: incurredOn, supplier: nil,
                description: category == .other ? otherNote.recorded : nil)
            draft.allocationBasis = .holding
            if category == .payroll, payrollMode == .perPerson, let headcount, let perPerson {
                draft.payrollHeadcount = headcount
                draft.payrollAnnualPerPerson = perPerson
            }
            return draft
        }
    }

    enum Problem: Equatable {
        case nothingEntered
        case unreadable(CostCategory)
        case notPositive(CostCategory)
        case tooLarge(CostCategory)
        /// Per person, with one of the two left out: the server takes both or
        /// neither, and one alone cannot be shown.
        case peopleIncomplete
    }

    /// Said before the request, first one first.
    var problems: [Problem] {
        var found: [Problem] = []
        if entered.isEmpty { found.append(.nothingEntered) }
        for category in entered {
            guard let amount = Self.amount(line(category).amountText) else {
                found.append(.unreadable(category)); continue
            }
            if amount <= 0 { found.append(.notPositive(category)) }
            if amount > CreateCostEntry.maxAmount { found.append(.tooLarge(category)) }
        }
        if payrollMode == .perPerson, (headcount == nil) != (perPerson == nil) {
            found.append(.peopleIncomplete)
        }
        return found
    }
}
