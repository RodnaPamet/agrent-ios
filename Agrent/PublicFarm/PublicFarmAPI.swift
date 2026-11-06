import Foundation

/// A farm's public page (`/f/{handle}`, agri-saas P6), read for the phone's
/// own screen (#536) rather than opened in Safari's view.
///
/// Anonymous on the server and the same for every reader: what the farm
/// chose to publish, its hidden fields already left out. A private page and
/// a missing one answer the same 404. The handle travels in the path only:
/// iOS logs whole URLs, so nothing about a person goes in a query.
enum PublicFarmAPI {
    static func path(_ handle: String) -> String { "/api/public/farms/\(URLEscape.segment(handle))" }
    /// Where a farm's pictures live. The profile names each one as a
    /// root-relative path (decided with agri-saas 2026-10-20: one rule for
    /// images, as `/me`'s `avatarUrl`), and only a path under this prefix
    /// is followed: the person's bearer never goes anywhere else.
    static func isOurMedia(_ path: String) -> Bool {
        guard path.first == "/" else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return parts.count == 4 && Array(parts.prefix(3)) == ["api", "public", "media"]
            && !parts[parts.startIndex + 3].isEmpty && parts[parts.startIndex + 3] != ".."
    }

    struct Farm: Decodable, Equatable, Sendable {
        let handle: String
        let displayName: String
        let tagline: String?
        let about: String?
        let oblast: String?
        let crops: [String]
        /// Root-relative, `/api/public/media/{hash}`, in display order.
        let logoUrl: String?
        let photoUrls: [String]

        private enum CodingKeys: String, CodingKey {
            case handle, displayName, tagline, about, oblast, crops, logoUrl, photoUrls
        }

        init(handle: String, displayName: String, tagline: String? = nil, about: String? = nil,
             oblast: String? = nil, crops: [String] = [], logoUrl: String? = nil, photoUrls: [String] = []) {
            self.handle = handle
            self.displayName = displayName
            self.tagline = tagline
            self.about = about
            self.oblast = oblast
            self.crops = crops
            self.logoUrl = logoUrl
            self.photoUrls = photoUrls
        }

        /// Every field but the name and handle may be absent: a farm shows
        /// what it published, and an odd value costs that value.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handle = try c.decode(String.self, forKey: .handle)
            displayName = try c.decode(String.self, forKey: .displayName)
            tagline = (try? c.decodeIfPresent(String.self, forKey: .tagline))?.recorded
            about = (try? c.decodeIfPresent(String.self, forKey: .about))?.recorded
            oblast = (try? c.decodeIfPresent(String.self, forKey: .oblast))?.recorded
            crops = ((try? c.decodeIfPresent([String].self, forKey: .crops)) ?? nil)?.compactMap(\.recorded) ?? []
            logoUrl = (try? c.decodeIfPresent(String.self, forKey: .logoUrl))?.recorded.flatMap {
                PublicFarmAPI.isOurMedia($0) ? $0 : nil
            }
            photoUrls = ((try? c.decodeIfPresent([String].self, forKey: .photoUrls)) ?? nil)?
                .compactMap(\.recorded).filter(PublicFarmAPI.isOurMedia) ?? []
        }
    }

    static func decode(from data: Data) async throws -> Farm {
        try await APIClient.shared.decode(data, as: Farm.self)
    }

    /// Not public, or no such farm: one answer, said as one.
    static func isNotPublic(_ error: Error) -> Bool {
        if case APIClient.APIError.http(404, _, _, _, _) = error { return true }
        return false
    }
}
