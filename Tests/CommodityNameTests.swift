import XCTest
@testable import Agrent

/// The owner reported the calculator showing "wheat". It was not the
/// calculator: a commodity name is server DATA rather than a UI label, so
/// nothing that translates labels was ever going to reach it, and eight
/// sites across three screens handed the server's string to a `Text`.
///
/// The table is the server's `trends.commodities.*`, taken rather than
/// written. `bg.json` holds TWO other crop vocabularies — `crops.*` is
/// Title-Case keyed, has six of the ten, and spells rapeseed `Canola`;
/// `journalEnums.crop.*` is the same six again. Writing a fourth would have
/// been the `taskEnums.status` versus `agStatus.operation` mistake.
final class CommodityNameTests: XCTestCase {

    // MARK: - Canonical slugs: calculator and exchange

    /// The reported bug.
    func testTheReportedWheatIsTranslated() {
        XCTAssertEqual(CommodityName.canonical("wheat"), "Пшеница")
    }

    /// All ten canonical commodities plus the five inputs, so a gap in the
    /// table is a failure here and not a word on a screen.
    func testTheWholeCanonicalVocabularyIsPresent() {
        let canonical = ["wheat", "maize", "barley", "sunflower", "rapeseed",
                         "oats", "rye", "soybean", "peas", "lentils"]
        let inputs = ["diesel", "urea", "dap", "map", "ammonium-nitrate"]
        for slug in canonical + inputs {
            let out = CommodityName.canonical(slug)
            XCTAssertNotNil(out)
            XCTAssertTrue(
                out!.unicodeScalars.contains { $0.value > 0x400 },
                "\(slug) → \(out!) is not Bulgarian"
            )
        }
        XCTAssertEqual(CommodityName.table.count, 15)
    }

    /// Rapeseed is the one the other vocabulary gets wrong: `crops.*` keys
    /// it as `Canola`. Taking the canonical table means the phone and the
    /// web agree.
    func testRapeseedUsesTheCanonicalSpelling() {
        XCTAssertEqual(CommodityName.canonical("rapeseed"), "Рапица")
        // `canola` is NOT a canonical slug, so it must degrade rather than
        // silently resolve — inventing an alias is how a fourth vocabulary
        // starts.
        XCTAssertEqual(CommodityName.canonical("canola"), "Canola")
    }

    /// An unknown slug title-cases the VALUE. A row written before the
    /// vocabulary was canonicalised can hold something in no catalogue, and
    /// `ammonium-nitrate` raw is worse than `Ammonium Nitrate`. The
    /// degraded state must never be the lookup key.
    func testAnUnknownSlugIsTitleCasedNotShownRaw() {
        XCTAssertEqual(CommodityName.canonical("sugar-beet"), "Sugar Beet")
        XCTAssertEqual(CommodityName.canonical("triticale"), "Triticale")
        XCTAssertFalse(CommodityName.canonical("foo")!.contains("."))
    }

    /// Case folding, because `commodity` is lowercase and nothing stops a
    /// future row from being otherwise.
    func testSlugLookupFoldsCase() {
        XCTAssertEqual(CommodityName.canonical("WHEAT"), "Пшеница")
        XCTAssertEqual(CommodityName.canonical("  Wheat  "), "Пшеница")
    }

    // MARK: - Free text: parcels

    /// `Parcel.cropType` is Title-Case where `commodity` is lowercase. The
    /// same crop, two spellings, two screens — a table keyed literally
    /// would have fixed one and left the other, which looks finished and
    /// is not.
    func testTheTwoServerSpellingsResolveToTheSameWord() {
        XCTAssertEqual(CommodityName.freeText("Wheat"), "Пшеница")
        XCTAssertEqual(CommodityName.canonical("wheat"), "Пшеница")
    }

    /// FREE TEXT PASSES THROUGH EXACTLY. This tenant grows "Grass", which
    /// appears in no vocabulary in the server repo at all — seeding "Трева"
    /// would have been right by luck, and the next farm to type "Люцерна"
    /// or "Grass ley" needs a passthrough rather than a longer guess list.
    func testFreeTextPassesThroughUnchanged() {
        XCTAssertEqual(CommodityName.freeText("Grass"), "Grass")
        XCTAssertEqual(CommodityName.freeText("Люцерна"), "Люцерна")
        XCTAssertEqual(CommodityName.freeText("Sugar Beet Field 3"), "Sugar Beet Field 3")
    }

    /// And is NOT title-cased. It is already a display string somebody
    /// chose, so reformatting it is a change they did not ask for.
    func testFreeTextIsNotReformatted() {
        XCTAssertEqual(CommodityName.freeText("grass ley mix"), "grass ley mix")
    }

    // MARK: - Shape

    func testAbsentStaysAbsent() {
        for f in [CommodityName.canonical, CommodityName.freeText] {
            XCTAssertNil(f(nil))
            XCTAssertNil(f(""))
            XCTAssertNil(f("   "))
        }
    }

    /// Every key lowercase, or the case-folding lookup silently misses that
    /// entry — the one failure that reintroduces the original bug for a
    /// single commodity.
    func testEveryKeyIsLowercased() {
        for key in CommodityName.table.keys {
            XCTAssertEqual(key, key.lowercased(), "\(key) can never be matched")
        }
    }

    func testEveryValueIsBulgarian() {
        for (key, value) in CommodityName.table {
            XCTAssertTrue(
                value.unicodeScalars.contains { $0.value > 0x400 },
                "\(key) → \(value) is not Bulgarian"
            )
        }
    }
}
