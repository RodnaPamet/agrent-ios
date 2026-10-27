import MapKit
import UIKit

/// The orthophoto's tiles, through the farm's own API (`OrthophotoAPI`).
///
/// `canReplaceMapContent`: the photo IS the map here. Apple's imagery under
/// it would show through any tile the server has no photo for, and the two
/// sources disagree about where a field edge is by several metres, which on
/// a map of field edges is the one disagreement that matters.
///
/// With no signal, or no photo for a tile, it draws the schematic's plain
/// ground instead of MapKit's empty grid, so the parcels' and blocks'
/// outlines still read as a map. That is what replaced «Схема»'s offline
/// promise (owner, 2026-10-27).
final class OrthophotoTileOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        // The server clamps to 10–19 (agri-saas #2425): the source is 25 cm,
        // so beyond 19 a tile is the same pixels larger, and below 10 one
        // tile fans across the country. Asking outside it would be refused,
        // and a refusal is asked again forever.
        minimumZ = 10
        maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        // Signed in and stamped like every other read (`APIClient`), never
        // MapKit's own loader.
        do {
            let data = try await APIClient.shared.data(for: OrthophotoAPI.tilePath(path))
            // A 204 (no year has a photo here) or anything that isn't an
            // image: the ground, for good, as there is nothing to wait for.
            return !data.isEmpty && UIImage(data: data) != nil ? data : Self.groundTile
        } catch {
            // THROWN, not ground, unless the answer is final. MapKit keeps a
            // tile it was given for the rest of the session and asks again for
            // one that failed, so ground for a slow or failing server would
            // stick long after the server recovered. Ground only where there
            // is no photo (404) or no network: the offline promise.
            guard Self.isFinal(error) else { throw error }
            return Self.groundTile
        }
    }

    /// Whether a failed tile should be drawn as ground rather than asked for
    /// again: no photo for it, or no network at all.
    static func isFinal(_ error: Error) -> Bool {
        // 404: no photo, or no route yet. 501: the server doesn't implement
        // it at all, which the UI test seam also answers for a tile it has
        // no fixture for. Both are answers, not hiccups.
        if case APIClient.APIError.http(let status, _, _, _, _) = error, status == 404 || status == 501 { return true }
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff].contains(url.code)
    }

    /// The flat ground, one colour, made once.
    static let groundTile: Data = {
        let size = CGSize(width: 256, height: 256)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(Palette.Map.ground).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }()
}
