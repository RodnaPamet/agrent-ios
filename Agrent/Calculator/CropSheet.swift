import Foundation

/// The «Култура» half of «Нов разход» (#245): one crop's costs, each a rate
/// per decare, booked over the land the crop stands on.
///
/// Owner, 2026-10-09: «choose crop/overhead at the top - then the fields
/// update according to crop default per dca (rent, seed, fuel, prz [total or
/// manually added rows], fertilizers [total or manually added rows]»; the
/// defaults are the farm's own last values for that crop. Services keep the
/// place they had in the one-line form. Pure, so the rules are tests and the
/// sheet only draws them.
struct CropSheet: Equatable {
    /// One rate as its field holds it, and what the prefill knew about it.
    struct Row: Equatable, Identifiable {
        var id = UUID()
        /// What the row is — «Хербицид», «Амониева селитра». Optional; the
        /// line's description.
        var name = ""
        var perDcaText = ""
        var lastEnteredOn: Date?
        /// The rate as the farm entered it, in leva, when the prefill converted
        /// it to the sheet's euros at the fixed rate.
        var convertedFromLeva: Decimal?
        /// The last sheet had this line as a TOTAL, not per decare: named,
        /// left unfilled, and said so (agri-saas #1611).
        var lastWasTotal = false
        /// The last rate was in a currency the sheet does not convert, so it
        /// was not put in the field: said, rather than shown in the wrong
        /// currency.
        var unconvertedCurrency: String?

        var isBlank: Bool {
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && perDcaText.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var isEntered: Bool { !perDcaText.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// One category's rows.
    struct Group: Equatable, Identifiable {
        let category: CostCategory
        var rows: [Row]

        var id: CostCategory { category }

        /// Plant protection, fertiliser and services take rows of their own
        /// — the owner's «total or manually added rows». Rent, seed and fuel
        /// are one rate each.
        var takesRows: Bool { CropSheet.itemised.contains(category) }

        var isBlank: Bool { rows.allSatisfy(\.isBlank) }
    }

    static let categories: [CostCategory] = [.rent, .seed, .fuel, .pesticide, .fertilizer, .service]
    static let itemised: Set<CostCategory> = [.pesticide, .fertilizer, .service]

    /// The server's bound on one sheet (agri-saas #1604): one transaction.
    static let maxLines = 25

    var groups: [Group] = categories.map { Group(category: $0, rows: [Row()]) }

    mutating func addRow(to category: CostCategory) {
        guard let index = groups.firstIndex(where: { $0.category == category }) else { return }
        groups[index].rows.append(Row())
    }

    /// The last row of a group stays: a group with no rows has no field.
    mutating func removeRows(at offsets: IndexSet, from category: CostCategory) {
        guard let index = groups.firstIndex(where: { $0.category == category }) else { return }
        groups[index].rows.remove(atOffsets: offsets)
        if groups[index].rows.isEmpty { groups[index].rows = [Row()] }
    }

    /// One row by its id, for the action VoiceOver and Switch Control reach
    /// it by; the swipe stays for touch.
    mutating func removeRow(_ id: Row.ID, from category: CostCategory) {
        guard let index = groups.firstIndex(where: { $0.category == category }),
              let row = groups[index].rows.firstIndex(where: { $0.id == id }) else { return }
        removeRows(at: IndexSet(integer: row), from: category)
    }

    // MARK: - Prefill

    /// The crop's last sheet, row for row. Only a group still BLANK is filled:
    /// the defaults arrive after the crop is chosen, and a figure typed
    /// meanwhile is the farmer's.
    ///
    /// In the sheet's currency or not at all, as «Общи» does: a leva rate is
    /// converted at the changeover's fixed rate and says so; one in any other
    /// currency keeps its row and name, unfilled, and says why. A category
    /// this sheet does not list gets a group of its own after the others,
    /// rather than disappearing; one this build has never heard of cannot be
    /// sent back, so it is left out.
    mutating func prefill(from defaults: CropCostDefaults, currency: String) {
        var order: [CostCategory] = []
        var rows: [CostCategory: [Row]] = [:]
        for line in defaults.lines where line.category != .unknown {
            var row = Row(name: line.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                          lastEnteredOn: line.incurredOn)
            if let rate = line.amountPerDca?.value {
                if let converted = EuroChangeover.convert(rate, from: line.currency, to: currency) {
                    row.perDcaText = OverheadSheet.fieldText(converted)
                    row.convertedFromLeva = OverheadSheet.levaOrNil(rate, from: line.currency, to: currency)
                } else {
                    row.unconvertedCurrency = line.currency
                }
            } else {
                row.lastWasTotal = true
            }
            if rows[line.category] == nil { order.append(line.category) }
            rows[line.category, default: []].append(row)
        }
        for category in order {
            guard let found = rows[category] else { continue }
            if let index = groups.firstIndex(where: { $0.category == category }) {
                guard groups[index].isBlank else { continue }
                groups[index].rows = found
            } else {
                groups.append(Group(category: category, rows: found))
            }
        }
    }

    // MARK: - What goes out

    /// A rate × the crop's land, to the cent: what the books sum.
    static func total(perDca: Decimal, areaDca: Decimal) -> Decimal {
        var exact = perDca * areaDca
        var cents = Decimal()
        NSDecimalRound(&cents, &exact, 2, .plain)
        return cents
    }

    /// The rows with a rate typed, in the sheet's order.
    var entered: [(category: CostCategory, row: Row)] {
        groups.flatMap { group in group.rows.filter(\.isEntered).map { (group.category, $0) } }
    }

    /// The rates typed, added up: what a decare of this crop carries.
    var perDcaSum: Decimal? {
        let rates = entered.compactMap { OverheadSheet.amount($0.row.perDcaText) }.filter { $0 > 0 }
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }

    /// What the lines come to over the crop's land: each line's own cents,
    /// added, so it is the figure the books will hold.
    func totalAmount(areaDca: Decimal) -> Decimal? {
        let rates = entered.compactMap { OverheadSheet.amount($0.row.perDcaText) }.filter { $0 > 0 }
        return rates.isEmpty ? nil : rates.map { Self.total(perDca: $0, areaDca: areaDca) }.reduce(0, +)
    }

    /// One draft per row with a readable rate: the crop named, no land
    /// linked (`CROP`, agri-saas #1583), the rate as typed, and the amount it
    /// comes to over the crop's land. No season: the server takes the one
    /// containing the date.
    func drafts(crop: CropChoice, currency: String, incurredOn: String) -> [CreateCostEntry] {
        entered.compactMap { category, row in
            guard let rate = OverheadSheet.amount(row.perDcaText) else { return nil }
            var draft = CreateCostEntry(
                category: category, amount: Self.total(perDca: rate, areaDca: crop.areaDca),
                currency: currency, incurredOn: incurredOn, supplier: nil,
                description: row.name.recorded)
            draft.allocationBasis = .crop
            // The slug, for the server to resolve; never shown — the sheet
            // shows `CropChoice.name`, which is `CommodityName.canonical`.
            draft.commodityCanonical = crop.commodity
            draft.amountPerDca = rate
            return draft
        }
    }

    enum Problem: Equatable {
        case nothingEntered
        case unreadable(CostCategory)
        case notPositive(CostCategory)
        /// A rate so small that over this land it rounds to no cents: the
        /// server takes an amount above zero.
        case roundsToNothing(CostCategory)
        case tooLarge(CostCategory)
        case tooManyLines
    }

    /// Said before the request, first one first.
    func problems(areaDca: Decimal) -> [Problem] {
        var found: [Problem] = []
        let entered = entered
        if entered.isEmpty { found.append(.nothingEntered) }
        if entered.count > Self.maxLines { found.append(.tooManyLines) }
        for (category, row) in entered {
            guard let rate = OverheadSheet.amount(row.perDcaText) else {
                found.append(.unreadable(category)); continue
            }
            if rate <= 0 { found.append(.notPositive(category)); continue }
            let total = Self.total(perDca: rate, areaDca: areaDca)
            if total <= 0 { found.append(.roundsToNothing(category)) }
            if total > CreateCostEntry.maxAmount { found.append(.tooLarge(category)) }
        }
        return found
    }
}
