import MapKit
import XCTest
@testable import Agrent

/// «Ортофотокарта» (#458): the farm's API for the Ministry's orthophoto, its
/// flight date and its physical blocks (ФБ). Synthetic coordinates only.
@MainActor
final class OrthophotoTests: XCTestCase {

    private let box = OrthophotoAPI.Box(minLon: 24.6, minLat: 43.41, maxLon: 24.62, maxLat: 43.42)

    // MARK: - Paths

    func testThePathsAreTheFarmsOwn() {
        XCTAssertTrue(OrthophotoAPI.tilePath("16", "37040", "23681").hasSuffix("/ortho/tiles/16/37040/23681"),
                      OrthophotoAPI.tilePath("16", "37040", "23681"))
        XCTAssertTrue(OrthophotoAPI.tilePath(MKTileOverlayPath(x: 1, y: 2, z: 3, contentScaleFactor: 2))
            .hasSuffix("/ortho/tiles/3/1/2"))
        // Lon first, as GeoJSON and `BoundingBox`, and a dot whatever the
        // phone's locale: a comma would split the box into eight numbers.
        XCTAssertTrue(OrthophotoAPI.coveragePath(box).hasSuffix("/ortho/coverage?bbox=24.60000,43.41000,24.62000,43.42000"),
                      OrthophotoAPI.coveragePath(box))
        XCTAssertTrue(OrthophotoAPI.blocksPath(box).hasSuffix("/ortho/blocks?bbox=24.60000,43.41000,24.62000,43.42000"))
    }

    func testARegionBecomesItsBox() {
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43, longitude: 24),
                                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.04))
        let box = OrthophotoAPI.Box(region)
        XCTAssertEqual(box.minLon, 23.98, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 43.01, accuracy: 1e-9)
        XCTAssertEqual(box.span, 0.04, accuracy: 1e-9)
    }

    // MARK: - The flight date

    func testTheFooterSaysWhoseAndWhen() async throws {
        let read = try await APIClient.shared.decode(
            Data(#"{"year":2025,"flightDate":"2025-07-02","attribution":"МЗХ"}"#.utf8), as: OrthoCoverage.self)
        XCTAssertEqual(read.year, 2025)
        XCTAssertEqual(read.footer, "Ортофото: МЗХ, заснемане \(BgDate.full(try XCTUnwrap(BgDate.parseISODay("2025-07-02"))))")
        let none = try await APIClient.shared.decode(Data(#"{"year":null,"flightDate":null}"#.utf8), as: OrthoCoverage.self)
        XCTAssertEqual(none.footer, "Ортофото: МЗХ", "no date: only whose photo it is")
        let odd = try await APIClient.shared.decode(Data(#"{"year":"2025","flightDate":7}"#.utf8), as: OrthoCoverage.self)
        XCTAssertNil(odd.year)
        XCTAssertEqual(odd.footer, "Ортофото: МЗХ")
    }

    // MARK: - The blocks

    private let blocksJSON = #"""
        {"type":"FeatureCollection","truncated":false,"features":[
          {"type":"Feature","properties":{"id":"00000-101","usage":"Обработваеми земи","year":2025},
           "geometry":{"type":"MultiPolygon","coordinates":[[[[24.60,43.41],[24.61,43.41],[24.61,43.415],[24.60,43.415],[24.60,43.41]]]]}},
          {"type":"Feature","properties":{"id":"00000-102","usage":null},
           "geometry":{"type":"Polygon","coordinates":[[[24.611,43.41],[24.62,43.41],[24.62,43.42],[24.611,43.42],[24.611,43.41]],
                                                     [[24.613,43.412],[24.615,43.412],[24.615,43.414],[24.613,43.412]]]}},
          {"type":"Feature","properties":{"usage":"no id"},"geometry":{"type":"Polygon","coordinates":[]}},
          {"type":"Feature","properties":{"id":"00000-103"},"geometry":{"type":"Point","coordinates":[24.6,43.4]}}
        ]}
        """#

    /// A MultiPolygon and a Polygon both read; a feature with no number, or
    /// no area, costs itself and not the map.
    func testTheBlocksReadLeniently() async throws {
        let read = try await APIClient.shared.decode(Data(blocksJSON.utf8), as: OrthoBlocks.self)
        XCTAssertEqual(read.blocks.map(\.id), ["00000-101", "00000-102"])
        XCTAssertEqual(read.blocks[0].usage, "Обработваеми земи")
        XCTAssertNil(read.blocks[1].usage)
        XCTAssertFalse(read.truncated)

        let holed = read.blocks[1].mapPolygons
        XCTAssertEqual(holed.count, 1)
        XCTAssertEqual(holed[0].interiorPolygons?.count, 1, "the hole stays a hole")
        XCTAssertEqual(holed[0].blockID, "00000-102")
        let label = try XCTUnwrap(read.blocks[0].labelPoint)
        XCTAssertEqual(label.latitude, 43.4125, accuracy: 1e-9)
        XCTAssertEqual(label.longitude, 24.605, accuracy: 1e-9)
    }

    // MARK: - The store

    /// Out too far, nothing is read and the footer says to zoom in; the last
    /// area asked for wins over one still in flight.
    func testBlocksAreReadOnlyCloseEnough() async throws {
        var asked: [OrthophotoAPI.Box] = []
        let store = OrthophotoStore(coverage: { _ in OrthoCoverage(year: nil, flightDate: nil, attribution: nil) },
                                    blocks: { box in
                                        asked.append(box)
                                        return OrthoBlocks(blocks: [OrthoBlock(id: "00000-1", usage: nil, polygons: [])])
                                    })
        let far = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43, longitude: 24),
                                     span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        store.showBlocks(in: far)
        XCTAssertTrue(store.tooFarOut)
        XCTAssertEqual(store.blocks, [])

        // Out past the farm, its own blocks, by its bounds.
        let farm = OrthophotoAPI.Box(minLon: 24.0, minLat: 43.0, maxLon: 24.1, maxLat: 43.1)
        store.showBlocks(in: far, farm: farm)
        XCTAssertFalse(store.tooFarOut)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(asked.last, farm)
        asked.removeAll()

        let near = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43, longitude: 24),
                                      span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        store.showBlocks(in: near)
        XCTAssertFalse(store.tooFarOut)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(store.blocks.map(\.id), ["00000-1"])
        store.showBlocks(in: near)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(asked.count, 1, "the same view isn't read twice")
    }

    func testTheCoverageIsReadOncePerFarm() async {
        var reads = 0
        let store = OrthophotoStore(coverage: { _ in
            reads += 1
            return OrthoCoverage(year: 2025, flightDate: "2025-07-02", attribution: nil)
        }, blocks: { _ in OrthoBlocks(blocks: []) })
        await store.loadCoverage(box)
        await store.loadCoverage(box)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(store.coverage?.year, 2025)
    }

    /// Ground for good only where the answer is final: no photo, or no
    /// network. A slow or failing server is thrown, so MapKit asks again.
    func testOnlyAFinalFailureIsGround() {
        XCTAssertTrue(OrthophotoTileOverlay.isFinal(APIClient.APIError.http(status: 404, code: nil, message: nil)))
        XCTAssertTrue(OrthophotoTileOverlay.isFinal(URLError(.notConnectedToInternet)))
        XCTAssertFalse(OrthophotoTileOverlay.isFinal(URLError(.timedOut)), "a slow server is asked again")
        XCTAssertFalse(OrthophotoTileOverlay.isFinal(APIClient.APIError.http(status: 503, code: nil, message: nil)))
    }

    /// No signal, or no photo, draws the plain ground: never MapKit's grid.
    func testTheGroundTileIsAnImage() {
        XCTAssertNotNil(UIImage(data: OrthophotoTileOverlay.groundTile))
        XCTAssertTrue(OrthophotoTileOverlay().canReplaceMapContent)
        XCTAssertEqual(OrthophotoTileOverlay().minimumZ, 10, "the server's clamp")
        XCTAssertEqual(OrthophotoTileOverlay().maximumZ, 19)
    }
}
