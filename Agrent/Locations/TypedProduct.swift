import Foundation

/// A typed product name, read against the farm's catalogue (#237).
///
/// Owner, 2026-10-09: «remove all sample products and leave the product as
/// free text only». The name travels in the operation's payload and agri-saas
/// finds the farm's product of that name or creates it — so a record made with
/// no signal still queues and is resolved when it is sent, which is why the
/// server, not this app, does the creating. What the sheet decides here is
/// only what to ASK, and that has to agree with the server or a farmer meets a
/// refusal in a field:
///
/// - A NEW name on the product path is created as a PESTICIDE, and that needs
///   its ПРЗ registration number and quarantine period
///   (`newProductRegistration`; omitted → `PESTICIDE_REGULATORY_FIELDS_REQUIRED`).
///   On a match they are ignored — an operation never rewrites a stored
///   registration — so they are asked only when the name is new.
/// - The match is the server's unique index, `lower(name)` per farm: plain
///   lower-casing, NOT diacritic folding. «й» is not «и» there, and folding
///   would hide the two fields for a name the server is about to create.
/// - Only the TYPED text is trimmed, and the trimmed text is what is sent. A
///   stored name is compared as stored: trimming it too would match a name
///   the server does not, and hide the fields when it creates. Erring the
///   other way only asks for two fields the server then ignores.
enum TypedProduct: Equatable, Sendable {
    /// Nothing typed.
    case empty
    /// The farm's own product, one this path takes — sent by its stored name.
    case existing(InputItem)
    /// No product of the farm's has this name: the server creates it.
    case new
    /// Not a fertiliser, typed into the FERTILISER path. The server refuses
    /// it (`FERTILIZER_EXPECTED`), so the sheet says so before the request
    /// rather than after. Only that way round — see `classify`.
    case wrongKind(InputItem)
    /// A seeded «Generic …» archetype. A line planned with one can never be
    /// completed (agri-saas #1078), so it is never sent.
    case sample(InputItem)

    /// The text as it goes out. Trimmed and nothing more: the server trims
    /// and does NOT collapse inner whitespace — «Карате  Зеон» is not
    /// «Карате Зеон» to its index (agri-saas, 2026-10-09).
    static func cleaned(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `productName` / `fertilizerName` are `max(200)`, `CreateItemSchema.name`'s
    /// bound, measured as JavaScript measures a string — in UTF-16 units.
    static let maxLength = 200

    static func isTooLong(_ typed: String) -> Bool {
        cleaned(typed).utf16.count > maxLength
    }

    /// The server's rule, which is ONE-SIDED (agri-saas, owner's ruling
    /// 2026-10-09): the fertiliser path takes only a FERTILIZER — a plant
    /// protection product there would file into the wrong ДНЕВНИК table —
    /// while the product path takes ANY category, a fertiliser included.
    /// Liquid nitrogen goes through a sprayer: «Аква амониев 28%» typed under
    /// «Пръскане» is real work, and refusing it would be stricter than the
    /// server. (A two-sided rule shipped briefly and broke agri-saas's own
    /// demo; `PRODUCT_EXPECTED` is gone with it.)
    ///
    /// The server's lookup skips archetypes (`isArchetype: false`), so a
    /// sample's exact name would not be FOUND — it would collide with the
    /// sample on create and come back 409. Caught here as `.sample` first.
    static func classify(_ typed: String, spraying: Bool, catalogue: [InputItem]) -> TypedProduct {
        let name = cleaned(typed)
        guard !name.isEmpty else { return .empty }
        let key = name.lowercased()
        let named = catalogue.filter { $0.name.lowercased() == key }
        // The farm's own row first, should a sample ever share its name.
        guard let match = named.first(where: { !$0.isArchetype }) else {
            return named.first.map(TypedProduct.sample) ?? .new
        }
        return spraying || match.isFertilizer ? .existing(match) : .wrongKind(match)
    }

    /// The farm's own products this path takes whose names contain what is
    /// typed — so «Карате» offers «Карате Зеон 5 CS» rather than a second,
    /// slightly different product. The catalogue's history is the reason:
    /// it holds one misspelt name, created twice. Nothing while the typed
    /// text is short or already a product's name, and never a sample.
    static func suggestions(for typed: String, spraying: Bool, in catalogue: [InputItem],
                            limit: Int = 3) -> [InputItem] {
        let key = cleaned(typed).lowercased()
        guard key.count >= 2,
              !catalogue.contains(where: { $0.name.lowercased() == key }) else { return [] }
        let found = catalogue.filter {
            !$0.isArchetype && (spraying || $0.isFertilizer) && $0.name.lowercased().contains(key)
        }
        return Array(found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }.prefix(limit))
    }
}
