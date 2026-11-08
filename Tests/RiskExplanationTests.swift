import XCTest
@testable import Agrent

/// The app's own words under a parcel's «Риск» (owner, 2026-11-07): one
/// reading of each pair of levels, Bulgarian sentences, the bare-field
/// caveat whenever greenness is low, and the stale image said.
final class RiskExplanationTests: XCTestCase {

    /// Every pair of known levels has its words, each a Bulgarian sentence.
    func testEveryPairIsExplained() throws {
        let known: [RiskLevel] = [.good, .watch, .stress]
        for vegetation in known {
            for moisture in known {
                let text = try XCTUnwrap(RiskExplanation.text(vegetation: vegetation, moisture: moisture, stale: false),
                                         "\(vegetation)/\(moisture)")
                XCTAssertTrue(UserMessage.isBulgarianSentence(text), text)
                XCTAssertTrue(text.hasSuffix("."), text)
                XCTAssertFalse(text.contains("·"), text)
            }
        }
    }

    /// Bare ground (agri-saas #2866): moisture is not graded, so no drought
    /// is named, whatever the soil after a week of rain.
    func testBareGroundNamesNoDrought() throws {
        let text = try XCTUnwrap(RiskExplanation.text(vegetation: .stress, moisture: .notAssessed, stale: false))
        XCTAssertTrue(text.hasPrefix("Зеленината е много ниска: на парцела вероятно няма култура"), text)
        XCTAssertTrue(text.contains("влагата не се оценява"), text)
        for word in ["засушаване", "суша", "сухо"] { XCTAssertFalse(text.contains(word), word) }
        let stale = try XCTUnwrap(RiskExplanation.text(vegetation: .stress, moisture: .notAssessed, stale: true))
        XCTAssertTrue(stale.contains("отпреди повече от"), stale)
    }

    /// The pair points at a cause: weak AND dry is drought, weak but not dry
    /// is something else, green but dry is drought on its way.
    func testThePairPointsAtACause() throws {
        let drought = try XCTUnwrap(RiskExplanation.text(vegetation: .stress, moisture: .stress, stale: false))
        XCTAssertTrue(drought.contains("засушаване"), drought)
        let notDrought = try XCTUnwrap(RiskExplanation.text(vegetation: .stress, moisture: .good, stale: false))
        XCTAssertTrue(notDrought.contains("не е сушата"), notDrought)
        let coming = try XCTUnwrap(RiskExplanation.text(vegetation: .good, moisture: .stress, stale: false))
        XCTAssertTrue(coming.contains("сушата идва"), coming)
        let fine = try XCTUnwrap(RiskExplanation.text(vegetation: .good, moisture: .good, stale: false))
        XCTAssertTrue(fine.contains("няма признаци на проблем"), fine)
    }

    /// A bare field reads as low greenness: said whenever greenness is low,
    /// never when it is good.
    func testABareFieldIsSaidWhenGreennessIsLow() throws {
        for vegetation in [RiskLevel.watch, .stress] {
            let text = try XCTUnwrap(RiskExplanation.text(vegetation: vegetation, moisture: .good, stale: false))
            XCTAssertTrue(text.contains("полето е празно"), text)
        }
        let good = try XCTUnwrap(RiskExplanation.text(vegetation: .good, moisture: .stress, stale: false))
        XCTAssertFalse(good.contains("полето е празно"), good)
    }

    func testAStaleImageIsSaidAndNoReadingIsSaid() throws {
        let stale = try XCTUnwrap(RiskExplanation.text(vegetation: .good, moisture: .good, stale: true))
        XCTAssertTrue(stale.contains("отпреди повече от \(Staleness.satellitePass) дни"), stale)
        let none = try XCTUnwrap(RiskExplanation.text(vegetation: .unknown, moisture: .good, stale: false))
        XCTAssertTrue(none.contains("няма оценка"), none)
        XCTAssertNil(RiskExplanation.text(vegetation: .unknown, moisture: .unknown, stale: true),
                     "an old image with no reading: the date line already says it")
    }
}
