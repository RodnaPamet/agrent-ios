import MapKit
import SwiftUI
import XCTest
@testable import Agrent

/// What Increase Contrast changes on the satellite map, in each of its two
/// shapes (agrent-ios#303).
///
/// «Точни очертания» is the map Локации opens in, and its style never read
/// the setting: the owner compared it on and off on the phone and saw no
/// difference. Checked on the renderer the coordinator styles, which is what
/// MapKit draws from.
@MainActor
final class SatelliteParcelMapStyleTests: XCTestCase {

    /// A made-up square; no parcel anywhere.
    private func styled(_ shape: SatelliteParcelMap.ParcelShape, contrast: ColorSchemeContrast,
                        tiles: Bool = false) -> MKPolygonRenderer {
        let coordinator = SatelliteParcelMap.Coordinator()
        coordinator.shape = shape
        coordinator.contrast = contrast
        coordinator.hasOverlay = tiles
        var corners = [
            CLLocationCoordinate2D(latitude: 1, longitude: 1), CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 2, longitude: 2), CLLocationCoordinate2D(latitude: 2, longitude: 1),
        ]
        let polygon = MKPolygon(coordinates: &corners, count: corners.count)
        let renderer = MKPolygonRenderer(polygon: polygon)
        coordinator.style(renderer, for: polygon)
        return renderer
    }

    private func alpha(_ color: UIColor?) -> CGFloat {
        var alpha: CGFloat = -1
        color?.getWhite(nil, alpha: &alpha)
        return alpha
    }

    func testIncreaseContrastDrawsThePreciseOutlineHeavier() {
        let standard = styled(.outlines, contrast: .standard).lineWidth
        let increased = styled(.outlines, contrast: .increased).lineWidth
        XCTAssertEqual(standard, 2)
        XCTAssertGreaterThan(increased, standard, "«Точни очертания» looks the same with Increase Contrast on")
        // The same heavy line as the other two maps draw.
        XCTAssertEqual(increased, styled(.boundingBoxes, contrast: .increased).lineWidth)
    }

    /// The index tiles are the data on the precise map; no setting may put a
    /// fill over them.
    func testTheIndexTilesAreNeverCoveredByAFill() {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            XCTAssertEqual(alpha(styled(.outlines, contrast: contrast, tiles: true).fillColor), 0)
        }
    }

    /// The simplified map is as it was: the fill near-solid and the border
    /// heavier with the setting on.
    func testTheSimplifiedMapStillAnswersTheSetting() {
        let standard = styled(.boundingBoxes, contrast: .standard)
        let increased = styled(.boundingBoxes, contrast: .increased)
        XCTAssertEqual(alpha(standard.fillColor), Palette.Map.fillOpacity(.standard), accuracy: 0.01)
        XCTAssertEqual(alpha(increased.fillColor), Palette.Map.fillOpacity(.increased), accuracy: 0.01)
        XCTAssertGreaterThan(increased.lineWidth, standard.lineWidth)
    }
}
