import Foundation

/// The farm's last overhead figures (#245): agri-saas
/// `GET /grain/costs/defaults` → `{ overheads: [...] }` (#1523).
///
/// The OWNER'S rule for defaults (2026-10-09): the farm's own last values,
/// never an Agrent-wide table — so an empty list is the first run, not a
/// failure. One line per category the farm has history for: PAYROLL, CREDIT,
/// DEPRECIATION, OTHER. RENT is not here: it is a crop line, per decare.
struct OverheadDefaults: Decodable, Equatable, Sendable {
    let overheads: [Line]

    struct Line: Decodable, Equatable, Sendable {
        let category: CostCategory
        let amount: WireDecimal
        let currency: String
        /// Shown beside the prefill: last season's figure, entered silently,
        /// would read as this year's.
        let incurredOn: Date
        /// NULL, never zero, when a plain total was entered — a prefill that
        /// wrote zeros here would replace a real figure with one nobody typed.
        let payrollHeadcount: Int?
        let payrollAnnualPerPerson: WireDecimal?
    }

    func line(_ category: CostCategory) -> Line? {
        overheads.first { $0.category == category }
    }
}

/// The machine register's straight-line depreciation (agri-saas
/// `GET /costs/machinery`, documented #1506): what «Амортизация» is offered.
///
/// Every field below is there because missing it renders a plausible WRONG
/// number (agri-saas backend 1, 2026-10-09):
/// - `method: NONE` is «not computed», NOT zero cost;
/// - `unallocatedCost` is machines with a cost and no charge, so the total
///   is understated by it and nothing else says so;
/// - `truncated` means the totals are partial.
struct MachineryDepreciation: Decodable, Equatable, Sendable {
    /// `NONE` or `STRAIGHT_LINE` — read as a string, so a method this build
    /// does not know is not a decode failure on a form.
    let method: String
    let totalAnnualCharge: WireDecimal
    let unallocatedCost: WireDecimal
    let unallocated: [Unallocated]
    let truncated: Bool

    struct Unallocated: Decodable, Equatable, Sendable {
        let assetName: String
        /// A GROWING union (`NO_USEFUL_LIFE` today) — an unknown value is
        /// «not depreciated», never an error.
        let reason: String
    }

    /// The figure to offer, or nil when the register does not compute one.
    var offered: Decimal? {
        method == "NONE" ? nil : totalAnnualCharge.value
    }

    /// What the offer does not include — said, because the total alone looks
    /// authoritative. Each a sentence.
    var caveats: [String] {
        guard method != "NONE" else {
            return ["Регистърът на техниката не изчислява амортизация."]
        }
        var found: [String] = []
        if !unallocated.isEmpty, unallocatedCost.value > 0 {
            found.append(unallocated.count == 1
                ? "1 машина без срок на ползване не е включена — сумата е занижена."
                : "\(unallocated.count) машини без срок на ползване не са включени — сумата е занижена.")
        }
        if truncated {
            found.append("Регистърът е съкратен — сумата е частична.")
        }
        return found
    }
}
