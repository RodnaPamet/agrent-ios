import Foundation

/// The premium arithmetic, in integer cents, matching the server's engine.
///
/// ── Why this exists at all, when the server is authoritative ──
///
/// `POST /insurance/leads` carries NO price field and the schema strips one if
/// it is sent. The server recomputes from the four inputs and ITS figure is
/// what gets stored and emailed. So nothing here decides anything — it exists
/// so a farmer standing in a field can see what an ask will cost before
/// committing to a write that cannot be taken back, and so that they can work
/// it out with no connection.
///
/// Which means the one rule that matters is about disagreement: when the
/// server's `quote` differs from this, the SERVER's number is shown. A local
/// figure that quietly wins would be the farmer reading one price while the
/// operator receives another.
///
/// ── Integers throughout, and why a Double would pass the easy cases ──
///
/// Cents and basis points, never a floating-point currency value. The
/// reference case that separates the two implementations is 250 dca at
/// 37 500,55 over four instalments: it lands exactly on a half-cent, so
/// round-half-up matters, and it leaves two leftover cents, so which
/// instalment absorbs them matters. A `Double` implementation gets the first
/// two reference cases right and this one wrong, which is the worst way for it
/// to be wrong.
enum InsurancePremium {

    /// Basis points, provisional and compiled in — SEE THE WARNING.
    ///
    /// A flat 1000 bp (10%) on every product today. This value being here at
    /// all is a known defect of the same class this repo has spent a week
    /// removing: a second description of one thing. Change it server-side and
    /// every preview in every installed copy is silently wrong, while the
    /// server's recompute is what reaches the operator.
    ///
    /// The server session has been asked for the tariff and the product
    /// catalogue as an ENDPOINT so this constant can be deleted. Until that
    /// lands, `quote(...)` takes the tariff as a parameter rather than reading
    /// this directly, so the call sites are already shaped for a fetched
    /// value and only the default has to go.
    static let provisionalTariffBp = 1000

    /// What an ask will cost, and how it splits.
    ///
    /// `premiumCents = floor((sumInsuredCents * tariffBp + 5_000) / 10_000)`
    /// — round-half-up on a basis-point rate. The `+ 5_000` is half of the
    /// 10 000 divisor, which is what makes it half-UP rather than truncation:
    /// at exactly x.5 cents it goes to x+1.
    ///
    /// The split gives the LEFTOVER CENTS TO THE FIRST instalment, so the
    /// parts sum back to the total exactly. A farmer paying in four sees
    /// 937.53 then 937.51 three times, not four times 937.51 and a missing
    /// two cents.
    static func quote(sumInsuredCents: Int, tariffBp: Int = provisionalTariffBp,
                      instalments: Int) -> Quote? {
        guard sumInsuredCents > 0, tariffBp > 0, (1...4).contains(instalments)
        else { return nil }

        let premiumCents = (sumInsuredCents * tariffBp + 5_000) / 10_000
        guard premiumCents > 0 else { return nil }

        let base = premiumCents / instalments
        let first = premiumCents - base * (instalments - 1)
        let parts = [first] + Array(repeating: base, count: instalments - 1)

        return Quote(premiumCents: premiumCents, instalmentsCents: parts,
                     tariffBp: tariffBp)
    }

    struct Quote: Equatable, Sendable {
        let premiumCents: Int
        let instalmentsCents: [Int]
        let tariffBp: Int

        /// DISPLAY ONLY, and the server's note about it is worth keeping: never
        /// multiply a per-decare figure back up to reach a total. It is the
        /// premium divided by an area that may itself be fractional, so it
        /// rounds, and rounding it twice is how a total drifts by cents.
        func perDecareCents(areaDca: Double) -> Int? {
            guard areaDca > 0 else { return nil }
            return Int((Double(premiumCents) / areaDca).rounded())
        }
    }

    /// Cents as «10 000,00 EUR».
    ///
    /// ALWAYS TWO DECIMALS, unlike `Num.text`, which drops trailing zeros. A
    /// premium of «3 750,6» reads as an unfinished number where «3 750,60»
    /// reads as money, and this figure is the one a farmer decides on.
    ///
    /// FORCED TO bg_BG, for the reason `Num` records: a formatter with no
    /// locale reads the PROCESS's, and this phone reports en_BG — so «10
    /// 000,00» became «10,000.00» the moment the region was not European,
    /// while the `Text` two lines above it stayed Bulgarian.
    ///
    /// The ISO code rather than «€»: `RefusalText` already established that
    /// currency codes are substituted as-is here, and the server talks in EUR.
    static func eur(_ cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "bg_BG")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? String(format: "%.2f", Double(cents) / 100)
        return "\(text) EUR"
    }

    // MARK: - Reading what a farmer typed

    /// MONEY AND AREA PARSE DIFFERENTLY, deliberately, and the asymmetry is
    /// the server's.
    ///
    /// For MONEY a single separator followed by exactly three digits means
    /// THOUSANDS — «100 000» and «100.000» are both one hundred thousand,
    /// because that is how the sum insured on a field gets typed and nobody
    /// means a tenth of a cent. For AREA both «,» and «.» are ALWAYS decimal:
    /// «12,345» is 12.345 dca, because parcels are fractional and no farm has
    /// twelve thousand decares in one parcel.
    ///
    /// The cost of the money rule, stated rather than discovered: «0,123» reads
    /// as 123. A sum insured below one currency unit is not a thing this form
    /// can express, and the alternative — making three digits sometimes
    /// decimal — would make «100 000» ambiguous, which is the case that
    /// actually occurs.
    static func moneyCents(_ text: String) -> Int? {
        let groups = separatedGroups(text)
        guard let groups, let last = groups.last else { return nil }

        // Exactly three digits after the final separator: the whole thing is
        // an integer amount and every separator was a thousands mark.
        if groups.count > 1, last.count == 3 {
            guard let whole = Int(groups.joined()) else { return nil }
            return whole * 100
        }

        let wholeDigits = groups.count > 1 ? groups.dropLast().joined() : last
        let fraction = groups.count > 1 ? last : ""

        // More than two fractional digits is REFUSED rather than truncated.
        // Silently dropping a digit from a sum insured is the kind of wrong
        // that reaches an operator as a real number.
        guard fraction.count <= 2, let whole = Int(wholeDigits) else { return nil }

        let cents = fraction.isEmpty ? 0 : Int(fraction.padding(
            toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        return whole * 100 + cents
    }

    /// Decares. Both separators are decimal here — see `moneyCents`.
    static func areaDecares(_ text: String) -> Double? {
        let groups = separatedGroups(text)
        guard let groups, let last = groups.last else { return nil }
        if groups.count == 1 { return Double(last) }
        return Double(groups.dropLast().joined() + "." + last)
    }

    /// Digits split on every separator a keyboard might produce, or nil when
    /// the text is not a number at all. A non-breaking space is included
    /// because that is what an iOS number pad's grouping inserts.
    private static func separatedGroups(_ text: String) -> [String]? {
        let separators = CharacterSet(charactersIn: ". ,\u{00A0}\u{202F}'")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let groups = trimmed
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        guard !groups.isEmpty,
              groups.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }

        // EVERY GROUP BETWEEN THE FIRST AND THE LAST MUST BE EXACTLY THREE
        // DIGITS, because that is what a thousands separator means.
        //
        // Without this, «1,2,3,4» read as 123.40 — the first three groups
        // concatenated into an integer part and the last taken as cents. Not a
        // rounding question: a farmer typing nonsense got a plausible sum
        // insured, and a plausible sum insured on this form reaches an
        // operator as a real number.
        //
        // Found by a test written to assert that nonsense is refused, which is
        // the direction this repo keeps having to be reminded to test in — the
        // parser's happy path was right from the first draft.
        //
        // The FIRST group is deliberately unconstrained: «12345,67» has no
        // thousands separator at all and 12345.67 is a perfectly ordinary
        // amount, so requiring 1–3 there would reject it.
        guard groups.count < 3 || groups.dropFirst().dropLast().allSatisfy({ $0.count == 3 })
        else { return nil }

        return groups
    }
}

/// The eight products the server's engine knows, PROVISIONALLY compiled in.
///
/// Same defect as `provisionalTariffBp` and the same plan: the catalogue has
/// been asked for as an endpoint. The `rawValue`s are the server's
/// `productKey` enum verbatim, so a fetched list drops straight in.
///
/// The labels are Bulgarian because every label in this app is. The five crops
/// go through `CommodityName` rather than being spelled here — a crop name is
/// server DATA and this repo has a CI guard saying so — and the three perils
/// have no commodity to resolve, so they are named here.
enum InsuranceProduct: String, CaseIterable, Identifiable, Sendable {
    case wheat, barley, maize, sunflower, rapeseed
    case drought, hail, frost

    var id: String { rawValue }

    /// Whether this is a crop policy or a peril policy. Only used to group
    /// the picker, so a farmer is not choosing between «Пшеница» and «Градушка»
    /// in one undifferentiated list of eight.
    var isCrop: Bool {
        switch self {
        case .wheat, .barley, .maize, .sunflower, .rapeseed: true
        case .drought, .hail, .frost: false
        }
    }

    var label: String {
        switch self {
        case .drought: "Суша"
        case .hail: "Градушка"
        case .frost: "Измръзване"
        default: CommodityName.canonical(rawValue) ?? rawValue
        }
    }
}
