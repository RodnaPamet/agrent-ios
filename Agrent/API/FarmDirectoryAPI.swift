import Foundation

/// The directory of published farms (P6.8, agri-saas #1817; agrent-ios #323).
///
/// ── Anonymous, and behind the same flag as the editor ──
///
/// `/api/public/farms` authenticates nothing: a stranger browsing the
/// directory has no account. The bearer this app sends anyway is ignored. It
/// answers 404 while `social.public-profile` is off, and Борса shows the
/// «Ферми» button only to someone the flag is on for, so the 404 is a
/// backstop, not a screen.
///
/// ── It reads only what a published page shows ──
///
/// Each hit comes from the public projection, which exists only while a farm
/// is published. A farm that withdraws leaves the directory at once, which is
/// why nothing here is cached: a copy on disk would keep showing it.
///
/// ── No paging ──
///
/// The server stops at 50 hits and has no cursor. Someone who needs more
/// narrows by oblast or crop, which is what the filters are for.
enum FarmDirectoryAPI {
    static let path = "/api/public/farms"

    /// The most the server returns, and what the phone always asks for.
    static let limit = 50

    static func searchPath(_ query: FarmDirectoryQuery) -> String {
        var items = ["limit=\(limit)"]
        if let q = query.wire(query.text, max: FarmDirectoryQuery.maxText) { items.append("q=\(q)") }
        if let oblast = query.wire(query.oblast, max: FarmDirectoryQuery.maxFilter) { items.append("oblast=\(oblast)") }
        if let crop = query.wire(query.crop, max: FarmDirectoryQuery.maxFilter) { items.append("crop=\(crop)") }
        return path + "?" + items.joined(separator: "&")
    }

    static func search(_ query: FarmDirectoryQuery) async throws -> [FarmDirectoryHit] {
        try decodeHits(from: try await APIClient.shared.data(for: searchPath(query)))
    }

    /// A bare array. A row without a handle or a name is dropped: it can be
    /// neither opened nor named. Anything that isn't an array fails, so a
    /// changed answer reads as an error rather than as an empty directory.
    static func decodeHits(from data: Data) throws -> [FarmDirectoryHit] {
        try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.hit)
    }

    private struct Lossy: Decodable {
        let hit: FarmDirectoryHit?
        init(from decoder: any Decoder) throws {
            hit = try? FarmDirectoryHit(from: decoder)
        }
    }
}

/// What the directory is being asked for.
struct FarmDirectoryQuery: Equatable, Sendable {
    var text = ""
    var oblast: String?
    var crop: String?

    /// The server's own bounds. Over them it answers 400, so a longer value
    /// is cut here instead: no farm's name is 120 characters long.
    static let maxText = 120
    static let maxFilter = 80

    var isFiltered: Bool { oblast != nil || crop != nil }

    /// Trimmed, cut to the bound, and escaped once, as `URLEscape` asks of
    /// every builder. Empty is left out: the server reads an empty query as
    /// browse, and so does an absent one.
    fileprivate func wire(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        return trimmed.isEmpty ? nil : URLEscape.queryValue(trimmed)
    }
}

/// One published farm, as the directory lists it. No description: that's on
/// the farm's page, which a tap opens.
///
/// `score` is left out. The server already orders the hits by it, and the
/// number means nothing to a person.
struct FarmDirectoryHit: Decodable, Equatable, Identifiable, Sendable {
    let handle: String
    let displayName: String
    var tagline: String?
    var oblast: String?
    var crops: [String]

    var id: String { handle }

    init(handle: String, displayName: String, tagline: String? = nil, oblast: String? = nil,
         crops: [String] = []) {
        self.handle = handle
        self.displayName = displayName
        self.tagline = tagline
        self.oblast = oblast
        self.crops = crops
    }

    private enum CodingKeys: String, CodingKey {
        case handle, displayName, tagline, oblast, crops
    }

    /// Strict on the two fields a row needs, lenient on the rest, like the
    /// other reads in the app.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decode(String.self, forKey: .displayName)
        tagline = Self.text((try? c.decodeIfPresent(String.self, forKey: .tagline)) ?? nil)
        oblast = Self.text((try? c.decodeIfPresent(String.self, forKey: .oblast)) ?? nil)
        crops = ((try? c.decodeIfPresent([String].self, forKey: .crops)) ?? [])
            .compactMap(Self.text)
    }

    /// Blank reads as absent, so a row never prints an empty line.
    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
