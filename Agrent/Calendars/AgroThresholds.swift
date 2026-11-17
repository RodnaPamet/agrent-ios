import Foundation
import Observation

/// Pest and disease thresholds (ПИВ, #636), from `GET /api/agro-thresholds`
/// (agri-saas#3157, no flag). МЗХ's integrated-production guide (2024): per
/// pest or disease, the crops it attacks and, per growth stage, the level
/// above which treating pays.
///
/// The threshold is the guide's own sentence, not a number: the phone shows
/// it and never judges a field against it (owner, 2026-11-17). Shown on the
/// calendar's crop page and in a parcel's «Риск» for the crop its РЕКОЛТИ
/// record names for this year.
///
/// Read leniently: an entry that does not read is left out, never the rest.
struct AgroThresholds: Decodable, Equatable, Sendable {
    let thresholds: [Threshold]

    struct Threshold: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let kind: Kind
        let name: AgroCalendar.Text
        let latin: String?
        let crops: [String]
        let levels: [Level]
        let note: AgroCalendar.Text?

        enum Kind: String, Decodable, Sendable { case disease, pest }

        var title: String { name.bg ?? id }

        private enum CodingKeys: String, CodingKey { case id, kind, name, latin, crops, levels, note }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            name = try c.decode(AgroCalendar.Text.self, forKey: .name)
            latin = try? c.decodeIfPresent(String.self, forKey: .latin)
            crops = try c.decode([String].self, forKey: .crops)
            levels = (try? c.decodeIfPresent(AgroCalendar.Lenient<Level>.self, forKey: .levels))?.values ?? []
            note = try? c.decodeIfPresent(AgroCalendar.Text.self, forKey: .note)
            // A threshold with no level that reads says nothing to act on.
            if levels.isEmpty { throw DecodingError.dataCorruptedError(forKey: .levels, in: c, debugDescription: "no levels") }
        }
    }

    struct Level: Decodable, Equatable, Hashable, Sendable {
        let stage: AgroCalendar.Text
        let threshold: AgroCalendar.Text
    }

    private enum CodingKeys: String, CodingKey { case thresholds }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thresholds = (try? c.decodeIfPresent(AgroCalendar.Lenient<Threshold>.self, forKey: .thresholds))?.values ?? []
    }

    /// A calendar crop's thresholds, by the commodity it joins.
    func `for`(_ crop: AgroCalendar.Crop) -> [Threshold] { self.for(crop.commodityCanonical) }

    /// A crop's thresholds, pests first then diseases, each in the guide's order.
    func `for`(_ commodity: String?) -> [Threshold] {
        guard let commodity else { return [] }
        let mine = thresholds.filter { $0.crops.contains(commodity) }
        return mine.filter { $0.kind == .pest } + mine.filter { $0.kind == .disease }
    }
}

extension AgroThresholds {
    /// The crop a parcel's РЕКОЛТИ record names for THIS harvest year, on the
    /// farm's clock (owner, 2026-11-17: «Риск» from this year's crop, nothing
    /// without one). The parcel's own crop label is not used: it is one
    /// overwritten field with no year (see `ParcelHistoryView.header`).
    /// Two seasons in one year (a catch crop): the later-sown one.
    static func thisYearsCrop(_ seasons: [CropSeason], now: Date = Date()) -> (slug: String, label: String)? {
        var sofia = Calendar(identifier: .gregorian)
        sofia.timeZone = TimeZone(identifier: "Europe/Sofia") ?? .current
        let year = sofia.component(.year, from: now)
        let candidates = seasons.filter { $0.year == year }
            .sorted { ($0.sownAt ?? .distantPast) > ($1.sownAt ?? .distantPast) }
        guard let season = candidates.first, let slug = CommodityName.slug(freeText: season.cropType) else { return nil }
        return (slug, season.cropLabel)
    }
}

enum AgroThresholdsAPI {
    static let path = "/api/agro-thresholds"

    static func decode(_ data: Data) async throws -> AgroThresholds {
        try await APIClient.shared.decode(data, as: AgroThresholds.self)
    }
}

/// Every threshold, cache first: one small payload, filtered on the phone.
@MainActor
@Observable
final class AgroThresholdsStore {
    private(set) var state: LoadState<AgroThresholds> = .loading

    func load() async {
        guard state.value == nil else { return }
        await CachedResource.loadShowingCacheFirst(AgroThresholdsAPI.path) { data in
            try await AgroThresholdsAPI.decode(data)
        } publish: { [weak self] answer in
            self?.state = answer
        }
    }
}

enum ThresholdWords {
    static let title = "Вредители и болести"
    static let note = "Прагът е по ръководството на МЗХ за интегрирано производство (2024). Сравнете го с това, което виждате на полето."
    static let pest = "Неприятел"
    static let disease = "Болест"

    /// «Прагове за вредители: Пшеница».
    static func riskRow(_ crop: String) -> String { "Прагове за вредители: \(crop)" }

    static func kind(_ kind: AgroThresholds.Threshold.Kind) -> String {
        kind == .pest ? pest : disease
    }
}
