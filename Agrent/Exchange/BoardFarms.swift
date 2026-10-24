import Foundation
import Observation

/// The farms Борса's one search finds (owner, 2026-10-24): the directory
/// folded into «Търсене по култура, регион или ферма», with the separate
/// «Ферми» screen gone.
///
/// ── The same question, asked of the directory ──
///
/// The board's `q` matches a crop or an oblast; the directory's `q` matches
/// only a farm's NAME (trigram similarity, agri-saas `searchPublicFarms`), and
/// narrows by crop and oblast through their own parameters. So what was typed
/// is read first:
///   - a crop («пшеница», `wheat`, «пше…» when only one crop starts so) goes
///     as `crop=Пшеница`, which the server compares ignoring case (#1909);
///   - an oblast («Плевен», «плев…» when unique) goes as `oblast=Плевен`;
///   - anything else is a farm's name, `q=`.
/// The oblasti tapped on the map narrow the farms as they narrow the board
/// (the owner's choice): the directory takes ONE oblast, so it is one request
/// per oblast, merged.
///
/// Nothing typed and no oblast chosen asks nothing: the board shows only
/// listings until someone searches.
enum BoardFarmSearch {
    enum Typed: Equatable {
        case none
        case name(String)
        case crop(String)
        case oblast(String)
    }

    static func queries(text: String, regions: [String]) -> [FarmDirectoryQuery] {
        let typed = read(text)
        if typed == .none, regions.isEmpty { return [] }
        let oblasts: [String?] = regions.isEmpty ? [nil] : regions.compactMap { BulgarianRegion.names[$0] }
        return oblasts.map { chosen in
            var query = FarmDirectoryQuery()
            switch typed {
            case .none: break
            case .name(let name): query.text = name
            case .crop(let crop): query.crop = crop
            // The map's oblast wins over a typed one: the board's listings are
            // narrowed by both, so a farm answer that ignored the map would
            // describe a different search.
            case .oblast(let oblast): query.oblast = oblast
            }
            if let chosen { query.oblast = chosen }
            return query
        }
    }

    /// What the typed text is: a crop, an oblast, or a name.
    static func read(_ text: String) -> Typed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let folded = fold(trimmed)
        if let crop = unique(folded, in: crops) { return .crop(crop) }
        if let oblast = unique(folded, in: oblasts) { return .oblast(oblast) }
        return .name(trimmed)
    }

    /// An exact match, or the one entry the text begins — at three letters or
    /// more, below which «с» or «со» starts several things and means none.
    private static func unique(_ folded: String, in names: [(key: String, name: String)]) -> String? {
        if let exact = names.first(where: { $0.key == folded }) { return exact.name }
        guard folded.count >= 3 else { return nil }
        let starting = Set(names.filter { $0.key.hasPrefix(folded) }.map(\.name))
        return starting.count == 1 ? starting.first : nil
    }

    private static func fold(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "bg_BG"))
    }

    /// The crops the exchange trades, by their Bulgarian name and the
    /// server's English slug, both pointing at the Bulgarian the farms type.
    /// Inputs (diesel, fertilisers) are left out, as the board's own search
    /// leaves them out: a farm does not "grow" urea.
    private static let crops: [(key: String, name: String)] = {
        let slugs = ["wheat", "maize", "barley", "sunflower", "rapeseed", "oats", "rye", "soybean", "peas", "lentils"]
        return slugs.flatMap { slug -> [(key: String, name: String)] in
            guard let name = CommodityName.table[slug] else { return [] }
            return [(key: fold(name), name: name), (key: slug, name: name)]
        }
    }()

    private static let oblasts: [(key: String, name: String)] =
        Set(BulgarianRegion.names.values).map { (key: fold($0), name: $0) }
}

/// The farms the board's search found, shown above the listings.
@Observable
@MainActor
final class BoardFarmsStore {
    private(set) var hits: [FarmDirectoryHit] = []

    /// Which search is the latest: a slow answer to an older one must not
    /// replace a newer one's.
    @ObservationIgnored private var asked = 0

    /// A failed directory read leaves NO farms rather than an error: the
    /// listings are the board, and a farm section is an addition to them. The
    /// directory answers 404 while `social.public-profile` is off, which the
    /// caller already checks.
    func load(text: String, regions: [String]) async {
        asked += 1
        let mine = asked
        let queries = BoardFarmSearch.queries(text: text, regions: regions)
        guard !queries.isEmpty else {
            hits = []
            return
        }
        let answers = await withTaskGroup(of: (Int, [FarmDirectoryHit]).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, (try? await FarmDirectoryAPI.search(query)) ?? []) }
            }
            var byIndex: [Int: [FarmDirectoryHit]] = [:]
            for await (index, found) in group { byIndex[index] = found }
            return queries.indices.flatMap { byIndex[$0] ?? [] }
        }
        guard mine == asked else { return }
        var seen = Set<String>()
        hits = answers.filter { seen.insert($0.handle).inserted }
    }

    func clear() {
        asked += 1
        hits = []
    }

    /// The server stops at `FarmDirectoryAPI.limit` with no next page, so a
    /// full answer says how to reach the rest.
    nonisolated static func footer(count: Int) -> String? {
        count >= FarmDirectoryAPI.limit
            ? "Показани са първите \(count) ферми. Стеснете търсенето."
            : nil
    }
}
