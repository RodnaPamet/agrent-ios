import XCTest
@testable import Agrent

/// «В страната» on Табло (#635): МЗХ's field-campaign progress, worded as the
/// owner approved it (2026-11-17).
final class CampaignProgressTests: XCTestCase {
    /// `GET /api/agro-progress` as agri-saas#3174 serves the 05.11.2026 bulletin.
    private func progress() throws -> CampaignProgress {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agro-progress", withExtension: "json"))
        let response = try JSONDecoder().decode(CampaignProgressResponse.self, from: Data(contentsOf: url))
        return try XCTUnwrap(response.progress)
    }

    /// Grouping separators are locale spaces (no-break or narrow); compare words.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testTheHarvestIsOneLineOfShares() throws {
        XCTAssertEqual(CampaignWords.harvest(try progress()), "Ожънати: слънчоглед 99%, царевица за зърно 92%")
    }

    func testEachSownCropIsALineWithHectaresAndTheChangeOnLastYear() throws {
        let lines = CampaignWords.sowing(try progress()).map(plain)
        XCTAssertEqual(lines.first, "Засети: пшеница 767 199 ха (+16,6% спрямо 2025)")
        XCTAssertTrue(lines.contains("Засети: ръж 2747 ха (−28,4% спрямо 2025)"))
        XCTAssertEqual(lines.count, 5)
    }

    func testTheDateAndTheSource() throws {
        XCTAssertEqual(CampaignWords.asOf(try progress().asOf), "към 5 ноември")
        XCTAssertEqual(CampaignWords.source, "Източник: МЗХ")
    }

    func testTheChangeIsSignedAndInBulgarianDecimals() {
        XCTAssertEqual(CampaignWords.changeText("16.6"), "+16,6%")
        XCTAssertEqual(CampaignWords.changeText("-28.4"), "−28,4%")
        XCTAssertEqual(CampaignWords.changeText("0.0"), "0,0%")
        XCTAssertNil(CampaignWords.changeText("няма"))
    }

    func testARowWithoutAChangeSaysOnlyTheHectares() throws {
        let json = #"{"progress":{"asOf":"2026-05-07","harvest":[],"sowing":[{"asOf":"2026-05-07","lastYear":2025,"rows":[{"label":"тютюн","sownHa":232,"lastYearHa":null,"changePct":null}]}]}}"#
        let p = try XCTUnwrap(try JSONDecoder().decode(CampaignProgressResponse.self, from: Data(json.utf8)).progress)
        XCTAssertEqual(CampaignWords.sowing(p), ["Засети: тютюн 232 ха"])
        XCTAssertNil(CampaignWords.harvest(p))
    }

    func testNoSnapshotYetIsNullNotAFailure() throws {
        let response = try JSONDecoder().decode(CampaignProgressResponse.self, from: Data(#"{"progress":null}"#.utf8))
        XCTAssertNil(response.progress)
    }

    /// The revamp (#671) resets a saved arrangement once to the new default;
    /// «В страната» is then off by default and a farmer's own later choice is
    /// kept across launches.
    @MainActor
    func testASavedTabloIsResetOnceToTheRevampedDefault() throws {
        let suite = "campaign-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["briefing", "grainPrice", "journal"], forKey: "dashboard.blocks")

        let first = DashboardPreferences(defaults: defaults)
        XCTAssertEqual(first.blocks, [.weather, .rainfall, .grainPrice])

        first.toggle(.campaign)
        XCTAssertEqual(DashboardPreferences(defaults: defaults).blocks, [.weather, .rainfall, .grainPrice, .campaign])
    }

    @MainActor
    func testANewTabloStartsFromTheRevampedDefault() throws {
        let suite = "campaign-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DashboardPreferences(defaults: defaults).blocks, DashboardBlock.defaultOrder)
        // Off by default since the revamp, still in the picker.
        XCTAssertFalse(DashboardBlock.defaultOrder.contains(.campaign))
        XCTAssertTrue(DashboardBlock.allCases.contains(.campaign))
    }
}
