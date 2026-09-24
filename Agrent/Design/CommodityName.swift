import Foundation

/// Commodity and crop names in Bulgarian.
///
/// ── The root cause, which is not "one missing translation" ──
///
/// A commodity name is server DATA, not a UI label, so nothing that
/// translates labels was ever going to reach it. Eight sites across
/// Калкулатор, Борса and Локации handed the server's string straight to a
/// `Text`, and a Bulgarian operator read `wheat`.
///
/// The web had the identical bug and fixed it in #484 — the Exchange list
/// rendered the slug verbatim there too. This is the second instance of one
/// defect, not a new one.
///
/// ── TWO FIELDS, TWO RULES, and the difference is not cosmetic ──
///
///     CalculatorRow.commodity    "wheat"     canonical slug, CLOSED set
///     ExchangeListing.commodity  "wheat"     same vocabulary, constrained
///                                            on write since #484
///     Parcel.cropType            "Wheat"     FREE TEXT, open set
///
/// `commodity` is `CanonicalCommodity`, not `String`: an identity, used by
/// the schema, the filter facets and the price-series aliases. It was never
/// meant to reach a `Text`. `cropType` is a per-tenant curated label with no
/// enum behind it — a farm may name a crop whatever it likes and still join
/// to a price series through a derived canonical field.
///
/// So the casing difference is deliberate and BOTH sides are right. One is a
/// market identity, one is a label.
///
/// ── The table is the server's, not mine ──
///
/// `trends.commodities.*`, keyed by the exact lowercase slug, verified
/// server-side as an exact 1:1 against `CANONICAL_COMMODITIES` +
/// `INPUT_COMMODITIES` with no slug unlabelled and no label orphaned.
///
/// There are two OTHER crop vocabularies in `bg.json` and both are traps:
/// `crops.*` is Title-Case keyed, has six of the ten, and spells rapeseed
/// **Canola**; `journalEnums.crop.*` is the same six again. Inventing a
/// fourth is the `taskEnums.status` versus `agStatus.operation` mistake, and
/// the reason this was asked about rather than written in ninety seconds.
enum CommodityName {

    /// A CANONICAL slug — `CalculatorRow.commodity`,
    /// `ExchangeListing.commodity`. Closed set, so the lookup is expected
    /// to hit.
    ///
    /// When it does not, the fallback TITLE-CASES THE SLUG rather than
    /// showing it raw: a row written before the vocabulary was
    /// canonicalised can hold a value in no catalogue, and
    /// `ammonium-nitrate` on screen is worse than `Ammonium Nitrate`. The
    /// degraded state is the VALUE, never the lookup key — the web's own
    /// note records that its i18n default would otherwise have printed
    /// `trends.commodities.foo` where the old code at least showed `foo`.
    static func canonical(_ slug: String?) -> String? {
        guard let slug else { return nil }
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return table[trimmed.lowercased()] ?? titleCased(trimmed)
    }

    /// FREE TEXT — `Parcel.cropType`. Open set, so a miss is ordinary
    /// rather than exceptional.
    ///
    /// Translated opportunistically when the farm happens to have typed a
    /// canonical name, and otherwise passed through EXACTLY as written.
    /// Not title-cased: this is already a display string somebody chose,
    /// and "Sugar Beet Field 3" is not an improvement on what they typed.
    ///
    /// This is why the table is not padded with plausible extras. The live
    /// tenant grows **Grass**, which appears in no vocabulary in the server
    /// repo at all — seeding "Трева" would have been right by luck, and the
    /// next farm to type "Люцерна" or "Grass ley" needs a passthrough, not
    /// a longer guess list.
    static func freeText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // THE PARCEL CATALOGUE FIRST, then the price series.
        //
        // These are two different server vocabularies and `freeText` serves
        // only one of them: every call site is a parcel's `cropType`, while
        // `canonical` serves listings, costs and price rows. Keeping the
        // tables apart is what lets `rapeseed` stay the canonical commodity
        // slug — an existing decision, with a test that says inventing an
        // alias "is how a fourth vocabulary starts" — while a parcel whose
        // catalogue word is `Canola` still reads «Рапица».
        //
        // Nothing invented here: the pairs are the web's `crops` namespace
        // verbatim, so the two clients cannot disagree about what to call a
        // field's crop depending on which one wrote it.
        if let crop = cropTable[trimmed.lowercased()] { return crop }
        if let known = table[trimmed.lowercased()] { return known }
        // AN UNMAPPED VALUE IS LEFT EXACTLY AS STORED.
        //
        // `cropType` is nullable free text and deliberately NOT validated
        // against the catalogue — production already holds `Grass`, which
        // is not in the picker's list, and validating strictly would have
        // made the farm's own data unwritable. So a farmer who typed
        // something sees what they typed. Same rule as the web's
        // `cropLabel`, and the same rule this app follows for free-text
        // weeds.
        //
        // The SCREAMING_SNAKE title-casing below is DEFENSIVE and honestly
        // so. I added it having seen `ALFALFA` beside «Пшеница» on the risk
        // screen — and that was MY OWN FIXTURE, invented for a screenshot
        // harness. The server owner checked: five distinct crop values
        // across every tenant, all TitleCase, no SCREAMING_SNAKE value
        // ever. It guards a shape this server does not emit, and is kept
        // only because an unvalidated column can hold whatever an import
        // writes.
        return isServerEnum(trimmed) ? titleCased(trimmed.lowercased()) : trimmed
    }

    /// `SUGAR_BEET` — uppercase ASCII with underscores and no spaces.
    /// Anything with a lowercase letter or a Cyrillic character is
    /// somebody's own words. No value of this shape has been observed in
    /// this server's data; see the note above.
    private static func isServerEnum(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy {
            ($0.isASCII && $0.isUppercase) || $0 == "_" || $0 == "-" || $0.isNumber
        }
    }

    /// `ammonium-nitrate` → `Ammonium Nitrate`.
    private static func titleCased(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `trends.commodities.*`, copied rather than paraphrased. Ten
    /// canonical commodities and five inputs — the inputs are here because
    /// the same slug space carries them, and a cost or a price series can
    /// name diesel as readily as wheat.
    /// What a PARCEL's `cropType` holds — the web's `crops` namespace,
    /// adopted verbatim from `crop-options.ts` rather than translated
    /// again here.
    ///
    /// Six catalogue values, TitleCase on the wire, matched case-insensitively.
    /// `Canola` is this vocabulary's word for what the price series calls
    /// `rapeseed`; both reach «Рапица» through their own table, which is
    /// how the phone and the web stay in agreement without either giving
    /// up its canonical slug.
    ///
    /// NOT COMPLETE, knowingly. Production holds `Grass` on one parcel and
    /// the catalogue has no such value, so the web renders it in English
    /// too. Adding a word here alone would make the two clients disagree,
    /// which is worse than one of them being in English — it is a
    /// vocabulary decision, and it is the owner's.
    static let cropTable: [String: String] = [
        "wheat": "Пшеница",
        "barley": "Ечемик",
        "canola": "Рапица",
        "maize": "Царевица",
        "sunflower": "Слънчоглед",
        "peas": "Грах",
    ]

    static let table: [String: String] = [
        "wheat": "Пшеница",
        "maize": "Царевица",
        "barley": "Ечемик",
        "sunflower": "Слънчоглед",
        "rapeseed": "Рапица",
        "oats": "Овес",
        "rye": "Ръж",
        "soybean": "Соя",
        "peas": "Грах",
        "lentils": "Леща",
        "diesel": "Нафта (дизелово гориво)",
        "urea": "Уреа (карбамид)",
        "dap": "ДАП (диамониев фосфат)",
        "map": "МАП (моноамониев фосфат)",
        "ammonium-nitrate": "Амониев нитрат",
    ]
}
