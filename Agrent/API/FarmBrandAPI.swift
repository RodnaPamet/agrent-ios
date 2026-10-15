import Foundation

/// A farm's public profile, as its administrators edit it (P6.6, agri-saas
/// #1815; agrent-ios #323). `FarmBrand` is the draft. The public page at
/// `/f/{handle}` is a projection of it, written only while it's published.
///
/// ── Behind a flag, on both sides ──
///
/// Every route here answers 404 while `social.public-profile` is off for the
/// caller (agri-saas #1888), the default. The phone shows the editor only to
/// someone the flag is on for (`FeatureFlags`), so the 404 is a backstop,
/// not a screen.
///
/// ── Admin only ──
///
/// The read and every write are `admin.manage`: the public face of a farm is
/// an owner's concern, and a read looser than the write would show a member
/// a draft they can't edit. The editor sits in Администрация, behind the
/// same gate.
///
/// ── No publishing yet (owner, 2026-10-15) ──
///
/// Publishing needs a recorded consent to a specific text, sent with that
/// text's version (`/farm-brand/consent`). The owner chose the web's wording
/// and version for the phone, and the web has none yet. So the phone edits,
/// claims an address and withdraws, and doesn't publish. `consentPath` is
/// here for the route guard and for the day the text exists.
enum FarmBrandAPI {
    static var draftPath: String { "\(FarmPath.root)/farm-brand" }
    static var handlePath: String { "\(draftPath)/handle" }
    static var publicationPath: String { "\(draftPath)/publication" }
    static var consentPath: String { "\(draftPath)/consent" }
    static var shareCardPath: String { "\(draftPath)/share-card" }

    /// The flag every P6 surface is behind.
    static let flag = "social.public-profile"

    /// The farm's draft, or nil when it has never had one: the server answers
    /// 200 with a null body for that (agri-saas #1891), not a 404, and the
    /// editor shows itself empty.
    static func draft() async throws -> FarmBrandDraft? {
        try decodeDraft(from: try await APIClient.shared.data(for: draftPath))
    }

    /// A body of `null` is "no draft". Anything else must read as one: the
    /// editor saves fields the person changed against it, and a guess at
    /// what was there would clear or keep the wrong ones.
    static func decodeDraft(from data: Data) throws -> FarmBrandDraft? {
        try JSONDecoder().decode(FarmBrandDraft?.self, from: data)
    }

    /// Saves the changed fields. The first save creates the draft.
    static func save(_ change: FarmBrandChange) async throws {
        _ = try await APIClient.shared.put(draftPath, body: change, as: SaveAnswer.self)
    }

    private struct SaveAnswer: Decodable {}

    /// Claims the web address. The server normalises it — transliterated,
    /// lower-cased — and the answer's `handle` is the one to show.
    static func claim(handle: String) async throws -> HandleClaim {
        try await APIClient.shared.put(handlePath, body: ["handle": handle], as: HandleClaim.self)
    }

    /// Takes the page down. Never refused for an incomplete draft: a farm must
    /// always be able to withdraw (agri-saas #1871).
    static func withdraw() async throws {
        _ = try await APIClient.shared.put(publicationPath, body: ["published": false], as: SaveAnswer.self)
    }

    /// The A6 card to print (P6.7, agri-saas #1910): the public name, the
    /// address and a QR code to it, as a PDF the server draws. Served only
    /// for a PUBLISHED farm (`FARM_BRAND_NOT_PUBLISHED`): a printed address
    /// that doesn't open would outlive any fix.
    ///
    /// Kept as the ДНЕВНИК is (`FarmRecordAPI.keep`): checked for `%PDF`
    /// and removed when Quick Look closes. The card holds nothing private,
    /// but one folder and one clean-up is simpler than a second of each.
    /// The server names the file after the farm; the fallback is the address.
    static func shareCard(handle: String) async throws -> URL {
        let (data, served) = try await APIClient.shared.getForDocument(shareCardPath)
        return try FarmRecordAPI.keep(data, named: FarmRecordAPI.fileName(served, fallback: shareCardFallbackName(handle)))
    }

    static func shareCardFallbackName(_ handle: String) -> String {
        "\(handle)-karta.pdf"
    }

    /// The alternatives a taken address was refused with: up to three,
    /// derived from the farm's own oblast and name. An EMPTY list is an
    /// answer too ("nothing to suggest"), so it isn't nil. nil means the
    /// refusal wasn't `FARM_HANDLE_TAKEN`.
    static func suggestions(after error: Error) -> [String]? {
        guard case APIClient.APIError.http(_, "FARM_HANDLE_TAKEN"?, _, let params, _) = error else { return nil }
        guard let joined = params?[APIClient.ErrorEnvelope.Err.suggestionsKey], !joined.isEmpty else { return [] }
        return joined.components(separatedBy: "\n")
    }
}

/// `GET /farm-brand`: wider than the public page. It carries `published`,
/// the consent record and `indexable`, which only the editor needs.
///
/// Lenient field by field, like the rest of the app's reads, except that a
/// body which isn't an object fails: see `FarmBrandAPI.decodeDraft`.
struct FarmBrandDraft: Decodable, Equatable, Sendable {
    var handle: String?
    var displayName: String?
    var tagline: String?
    var about: String?
    var oblast: String?
    var crops: [String]
    var published: Bool
    var consentedAt: Date?

    init(handle: String? = nil, displayName: String? = nil, tagline: String? = nil, about: String? = nil,
         oblast: String? = nil, crops: [String] = [], published: Bool = false, consentedAt: Date? = nil) {
        self.handle = handle
        self.displayName = displayName
        self.tagline = tagline
        self.about = about
        self.oblast = oblast
        self.crops = crops
        self.published = published
        self.consentedAt = consentedAt
    }

    private enum CodingKeys: String, CodingKey {
        case handle, displayName, tagline, about, oblast, crops, published, consentedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = (try? c.decodeIfPresent(String.self, forKey: .handle)) ?? nil
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        tagline = (try? c.decodeIfPresent(String.self, forKey: .tagline)) ?? nil
        about = (try? c.decodeIfPresent(String.self, forKey: .about)) ?? nil
        oblast = (try? c.decodeIfPresent(String.self, forKey: .oblast)) ?? nil
        crops = (try? c.decodeIfPresent([String].self, forKey: .crops)) ?? []
        published = (try? c.decodeIfPresent(Bool.self, forKey: .published)) ?? false
        consentedAt = ((try? c.decodeIfPresent(String.self, forKey: .consentedAt)) ?? nil)
            .flatMap(BgDate.parseInstant)
    }
}

/// `PUT /farm-brand`'s body: only what changed.
///
/// ── Left out is untouched; null clears ──
///
/// The server's rule (agri-saas #1871). A field the person didn't touch is
/// left out, so a save from this phone can't overwrite what someone else
/// wrote in another field meanwhile. A field emptied is sent as `null`,
/// which is how the server clears it. `crops` has no null: an empty list is
/// its cleared state.
struct FarmBrandChange: Encodable, Equatable, Sendable {
    enum Field: Equatable, Sendable {
        case set(String)
        case clear
    }

    var displayName: Field?
    var tagline: Field?
    var about: Field?
    var oblast: Field?
    var crops: [String]?

    var isEmpty: Bool { self == FarmBrandChange() }

    /// What the edited values change in the draft. Text is trimmed, and a
    /// field trimmed to nothing is a clear.
    static func between(_ draft: FarmBrandDraft?, and edited: FarmBrandDraft) -> FarmBrandChange {
        func field(_ before: String?, _ after: String?) -> Field? {
            let was = before?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let now = after?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard was != now else { return nil }
            return now.isEmpty ? .clear : .set(now)
        }
        let cropsNow = edited.crops
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return FarmBrandChange(
            displayName: field(draft?.displayName, edited.displayName),
            tagline: field(draft?.tagline, edited.tagline),
            about: field(draft?.about, edited.about),
            oblast: field(draft?.oblast, edited.oblast),
            crops: cropsNow == (draft?.crops ?? []) ? nil : cropsNow
        )
    }

    private enum CodingKeys: String, CodingKey { case displayName, tagline, about, oblast, crops }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ field: Field?, _ key: CodingKeys) throws {
            switch field {
            case .set(let value)?: try c.encode(value, forKey: key)
            case .clear?: try c.encodeNil(forKey: key)
            case nil: break
            }
        }
        try put(displayName, .displayName)
        try put(tagline, .tagline)
        try put(about, .about)
        try put(oblast, .oblast)
        try c.encodeIfPresent(crops, forKey: .crops)
    }
}

/// `PUT /farm-brand/handle`'s answer.
struct HandleClaim: Decodable, Equatable, Sendable {
    /// The address as stored and served: normalised, so often not what was
    /// typed (`Победа` → `pobeda`).
    let handle: String
    /// True when that differs from what was submitted.
    var normalised: Bool = false

    private enum CodingKeys: String, CodingKey { case handle, normalised }

    init(handle: String, normalised: Bool = false) {
        self.handle = handle
        self.normalised = normalised
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        normalised = (try? c.decodeIfPresent(Bool.self, forKey: .normalised)) ?? false
    }
}
