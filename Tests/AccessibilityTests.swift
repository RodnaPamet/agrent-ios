import CoreGraphics
import XCTest
@testable import Agrent

/// The `·` separator is the bug these exist for. Five screens built a subtitle
/// as `Text(crop); Text("·"); Text(area)`, which reads as one line and speaks
/// as three stops with "middle dot" in the middle. `children: .combine` does
/// not fix it — it concatenates the rendered text, separator included.
final class A11ySentenceTests: XCTestCase {

    func testJoinsWithCommasAndEndsWithAStop() {
        XCTAssertEqual(
            A11y.sentence(["Парцел 3", "Пшеница", "12,4 хектара"]),
            "Парцел 3, Пшеница, 12,4 хектара."
        )
    }

    /// The whole point: no separator character survives into speech.
    func testNoMiddleDotCanReachTheLabel() {
        let label = A11y.sentence(["Пшеница", "12,4 хектара", "под аренда"])
        XCTAssertFalse(label.contains("·"))
    }

    func testNilsAndBlanksAreDropped() {
        XCTAssertEqual(A11y.sentence(["Парцел", nil, "", "   ", "Угар"]), "Парцел, Угар.")
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(A11y.sentence([]), "")
        XCTAssertEqual(A11y.sentence([nil, "  "]), "")
    }

    /// A value that already ends in a stop must not collect a second one.
    func testExistingFullStopIsNotDoubled() {
        XCTAssertEqual(A11y.sentence(["Няма очертание."]), "Няма очертание.")
    }
}

/// Position is the one thing the schematic map knows that the parcel list
/// below it does not. Shape there is deliberately false and absolute size is
/// five times life; which field is north of which is the part still true.
final class A11yCompassTests: XCTestCase {

    /// Screen space: `dy` grows SOUTHWARD. Getting the sign wrong produces a
    /// map that is confidently upside down, which is worse than silence
    /// because it is still trusted.
    func testNorthIsNegativeY() {
        XCTAssertEqual(A11y.compass(dx: 0, dy: -100, deadband: 10), "север")
        XCTAssertEqual(A11y.compass(dx: 0, dy: 100, deadband: 10), "юг")
        XCTAssertEqual(A11y.compass(dx: 100, dy: 0, deadband: 10), "изток")
        XCTAssertEqual(A11y.compass(dx: -100, dy: 0, deadband: 10), "запад")
    }

    func testDiagonalsTakeTheCompoundName() {
        XCTAssertEqual(A11y.compass(dx: 100, dy: -100, deadband: 10), "североизток")
        XCTAssertEqual(A11y.compass(dx: -100, dy: -100, deadband: 10), "северозапад")
        XCTAssertEqual(A11y.compass(dx: 100, dy: 100, deadband: 10), "югоизток")
        XCTAssertEqual(A11y.compass(dx: -100, dy: 100, deadband: 10), "югозапад")
    }

    /// Inside the deadband every answer is wrong, and a confident wrong
    /// direction on a map is worse than none. nil lets the caller say
    /// something honest instead.
    func testInsideTheDeadbandThereIsNoDirection() {
        XCTAssertNil(A11y.compass(dx: 3, dy: 3, deadband: 10))
        XCTAssertNil(A11y.compass(dx: 0, dy: 0, deadband: 10))
    }

    func testNonFiniteInputProducesNoDirection() {
        XCTAssertNil(A11y.compass(dx: .nan, dy: 0, deadband: 10))
        XCTAssertNil(A11y.compass(dx: .infinity, dy: 0, deadband: .infinity))
    }

    /// Every bearing must land on one of the eight names, with none skipped
    /// and none reachable twice — an off-by-one in the sector arithmetic
    /// silently rotates the whole map by 45°, which no single case catches.
    func testEveryDirectionIsReachableAndTheSweepIsMonotonic() {
        var seen: [String] = []
        for degrees in stride(from: 0, to: 360, by: 5) {
            let radians = CGFloat(degrees) * .pi / 180
            // Negated to convert compass-from-north into screen dy.
            let name = A11y.compass(
                dx: sin(radians) * 100, dy: -cos(radians) * 100, deadband: 1
            )
            guard let name else { return XCTFail("no direction at \(degrees)°") }
            if seen.last != name { seen.append(name) }
        }
        // 0° starts on север and the sweep returns to it, so the run list
        // closes on the same name it opened with: 8 distinct + 1 wrap.
        XCTAssertEqual(seen.first, "север")
        XCTAssertEqual(seen.last, "север")
        XCTAssertEqual(Set(seen).count, 8, "a compass point is unreachable: \(seen)")
    }
}

/// The map's accessibility tree is computed from the same `layout` the drawing
/// pass uses, because a tree computed separately drifts — and drifts silently,
/// since the person who can see the screen never notices.
final class SchematicAccessibilityTests: XCTestCase {

    private func parcel(
        _ id: String, _ name: String, crop: String?, ha: Double?
    ) -> Parcel {
        Parcel(
            id: id, name: name, cropType: crop, areaHa: ha, geometry: nil,
            soilType: nil, cadastralId: nil, ekatte: nil, hasActiveLease: nil
        )
    }

    private func placement(_ p: Parcel, x: CGFloat, y: CGFloat) -> SchematicParcelMap.Placement {
        SchematicParcelMap.Placement(parcel: p, centre: CGPoint(x: x, y: y), side: 40)
    }

    /// The midpoint of the EXTENT, not the mean of the centres. Five parcels
    /// clustered with one far away would drag a mean into the cluster and
    /// report the five as lying in every direction from themselves.
    func testCentroidUsesExtentNotMean() {
        let p = parcel("1", "П", crop: nil, ha: nil)
        let clustered = (0..<5).map { placement(p, x: CGFloat(10 + $0), y: 10) }
        let distant = placement(p, x: 210, y: 10)
        let centre = SchematicParcelMap.centroid(of: clustered + [distant])
        XCTAssertEqual(centre.x, 110, accuracy: 0.001)
    }

    func testCentroidOfNothingIsOrigin() {
        XCTAssertEqual(SchematicParcelMap.centroid(of: []), .zero)
    }

    /// Sown/fallow is carried on screen by fill colour and a dashed stroke.
    /// Neither reaches this channel, so it has to be said.
    func testLabelNamesTheStateColourCarries() {
        let sown = placement(parcel("1", "Парцел 3", crop: "Пшеница", ha: 12.4), x: 200, y: 20)
        let label = SchematicParcelMap.label(
            for: sown, centre: CGPoint(x: 100, y: 100), count: 4
        )
        XCTAssertTrue(label.contains("засят"), label)
        XCTAssertTrue(label.contains("Пшеница"), label)
        // NOT the literal "12,4". `Num.text` formats for the DEVICE locale,
        // so the decimal separator is a comma here and a full stop on the
        // en_US CI runner — which is exactly how this test failed on its
        // first run: the app was right, the assertion had hard-coded an
        // environment it does not control. Asserted through the same
        // formatter the view uses, so it checks the wiring rather than the
        // runner's locale.
        XCTAssertTrue(label.contains(Area(hectares: 12.4).spoken), label)
        XCTAssertTrue(label.contains("североизток"), label)
    }

    func testParcelWithNoCropIsCalledFallow() {
        let fallow = placement(parcel("2", "Парцел 7", crop: nil, ha: 2.0), x: 100, y: 200)
        let label = SchematicParcelMap.label(
            for: fallow, centre: CGPoint(x: 100, y: 100), count: 4
        )
        XCTAssertTrue(label.contains("угар"), label)
        XCTAssertTrue(label.contains("юг"), label)
    }

    /// A lone parcel is not north of anything. Saying "в средата" there would
    /// be true and useless; saying a direction would be false.
    func testASingleParcelIsGivenNoPosition() {
        let only = placement(parcel("1", "Единствен", crop: nil, ha: 1), x: 100, y: 100)
        let label = SchematicParcelMap.label(
            for: only, centre: CGPoint(x: 100, y: 100), count: 1
        )
        XCTAssertEqual(label, "Единствен, угар, \(Area(hectares: 1).spoken).")
    }

    /// A parcel genuinely in the middle gets told so, rather than being given
    /// whichever direction the rounding happened to land on.
    func testACentralParcelIsCalledCentral() {
        let middle = placement(parcel("1", "Среден", crop: nil, ha: 1), x: 101, y: 100)
        let label = SchematicParcelMap.label(
            for: middle, centre: CGPoint(x: 100, y: 100), count: 4
        )
        XCTAssertTrue(label.contains("в средата"), label)
    }

    func testNoSeparatorCharacterReachesAMapLabel() {
        let p = placement(parcel("1", "Парцел", crop: "Ечемик", ha: 3.5), x: 10, y: 10)
        let label = SchematicParcelMap.label(
            for: p, centre: CGPoint(x: 100, y: 100), count: 3
        )
        XCTAssertFalse(label.contains("·"), label)
    }
}
