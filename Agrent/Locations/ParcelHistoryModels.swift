import Foundation

/// A parcel's agronomic archive: what it grew, what was applied to it, and
/// what was growing there that nobody planted.
///
/// ── Built from the generated spec, not from a conversation ──
///
/// Every field below was read from `src/generated/openapi.json` on the
/// agri-saas `main` branch (fetched 2026-09-25). That file is committed,
/// regenerated on every contract change, and a pre-commit hook fails the
/// commit if it drifts from the source modules — so it is the contract, and
/// a DTO relayed by hand is a copy of it with one more chance to be wrong.
/// Four times this month a declared contract here described something
/// untrue and survived because nothing checked it against reality; this is
/// the check.
///
/// ── What is deliberately NOT here ──
///
/// `GET /history` and its `ParcelHistory` envelope. The envelope is the part
/// still moving — an unbounded archive on one request, with a cap put to the
/// owner and not yet decided — so modelling it now would pin the one shape
/// that is expected to change. The ITEM schemas are settled, and the writes
/// and deletes are settled, which is what this file covers.
///
/// ── The three of them do not share a timeline type ──
///
/// A season is a YEAR, an operation is an INSTANT, an observation is a DAY
/// somebody walked the field. Merging them into one sorted feed reads well
/// on a mock and loses the only thing each is good for, so they stay three
/// lists.

// MARK: - What the parcel grew

/// One crop in one harvest year.
///
/// ── `year` is the HARVEST year and is never derived ──
///
/// The server says so explicitly, and gives the reason: wheat sown in
/// October 2025 is the 2026 harvest. Deriving the year from `sownAt` would
/// misfile most autumn cropping in Bulgaria by exactly one year — which is
/// the kind of wrong that looks right on a screen, because every row is
/// plausible and only the totals per year are nonsense.
///
/// So `year` is read, never computed, and `sownAt` is never consulted for
/// it. `ParcelHistoryTests` pins that with an October sowing.
///
/// ── More than one season per year is legal ──
///
/// A catch crop after an early harvest is ordinary practice, and the server
/// does not refuse it as a duplicate. Anything grouping these by year must
/// therefore handle 2+ entries in a group — `grouped(byYear:)` returns
/// arrays for that reason rather than a dictionary of single values.
struct CropSeason: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// The harvest year. Read, never derived — see the type's header.
    let year: Int
    /// FREE TEXT, open set. The server does not validate it against the crop
    /// catalogue, and says why: live data already holds values outside it,
    /// and refusing them would make the farm's own history un-recordable.
    /// So a picker offers the catalogue and accepts what they grew — and
    /// display goes through `CommodityName.freeText`, which leaves an
    /// unmapped value exactly as stored.
    let cropType: String
    let notes: String?

    /// The strings as they arrived. Parsed on demand rather than decoded,
    /// because the response schema pins no format — see
    /// `BgDate.parseInstantOrDay` for the asymmetry and what it costs to get
    /// wrong.
    let sownAtRaw: String?
    let harvestedAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, year, cropType, notes
        case sownAtRaw = "sownAt"
        case harvestedAtRaw = "harvestedAt"
    }

    /// OPTIONAL on purpose, and not only because the wire allows null: a
    /// back-filled season is often remembered without the drilling date.
    /// The server's own words. An archive whose earliest entry is the day
    /// the farm bought software is not an archive.
    var sownAt: Date? { BgDate.parseInstantOrDay(sownAtRaw) }
    var harvestedAt: Date? { BgDate.parseInstantOrDay(harvestedAtRaw) }

    /// «Пшеница», or the farm's own word for it.
    var cropLabel: String { CommodityName.freeText(cropType) ?? cropType }
}

extension Array where Element == CropSeason {
    /// Newest harvest year first, and every season in the year it was
    /// harvested in.
    ///
    /// Returns pairs rather than a dictionary because a dictionary has no
    /// order and this is a list on a screen, and arrays per year because a
    /// year can legally hold a catch crop as well as a main crop.
    func groupedByYear() -> [(year: Int, seasons: [CropSeason])] {
        Dictionary(grouping: self, by: \.year)
            .sorted { $0.key > $1.key }
            .map { (year: $0.key, seasons: $0.value) }
    }
}

// MARK: - What was applied

/// A COMPLETED field-operation line for this parcel.
///
/// ── A projection, not `OperationParcel` ──
///
/// These are the same database rows that record a spray or a fertiliser
/// application — which is why "linked completed tasks" and "what was
/// applied" are one list here and not two — but this is a narrower shape
/// with `productName` and `doseUnit` already resolved to strings. Reusing
/// the write model would mean carrying its unit IDs and its validation, and
/// inventing the fields this projection does not send.
///
/// PENDING LINES ARE ABSENT. A plan is not history, and the server filters
/// them out, so an empty list means nothing has been done to this parcel —
/// not that nothing is scheduled.
struct ParcelHistoryOperation: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// The task this line belongs to, for navigating to the operation
    /// itself. NOT the same as `id`, which identifies the line.
    let taskId: String
    let operationType: FieldOperationType?
    let doseUnit: String
    let targetNote: String?

    /// EMPTY means "not recorded", and all three of these can be empty.
    ///
    /// `title`, `productName` and `doseUnit` are each a `?? ''` collapse of an
    /// absent relation on the server — `line.task?.title`,
    /// `line.product?.name`, `line.doseUnit?.symbol` — and the spec now says
    /// so in this schema's description. They are `required` and `type: string`
    /// truthfully, because a string is what arrives; it is just sometimes the
    /// empty one. See `String.recorded`.
    ///
    /// Found on the server side by grep, not here: this client had already
    /// shipped the `doseUnit` case as a trailing space and would have shipped
    /// the other two the same way, because an empty title renders as a blank
    /// row rather than as an error.
    var title: String? { titleRaw.recorded }
    var productName: String? { productNameRaw.recorded }

    private let titleRaw: String
    private let productNameRaw: String

    /// A decimal STRING on the wire, and the server says what happens if
    /// that is ignored: "parsing it as a float rounds the dose". `л/дка` on
    /// a spray sheet is the number an operator sets a boom to.
    let doseValue: WireDecimal

    let completedAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, taskId, operationType, doseUnit, targetNote, doseValue
        case titleRaw = "title"
        case productNameRaw = "productName"
        case completedAtRaw = "completedAt"
    }

    var completedAt: Date? { BgDate.parseInstantOrDay(completedAtRaw) }

    /// THE SERVER'S OWN DIGITS, localised — deliberately NOT padded.
    ///
    /// `WireDecimal.text(scale:)` pads, and padding is right for money:
    /// `1234.5` becomes `1234,50` because the column IS `Decimal(14,2)` and
    /// `1234,50` is how money is written. A dose is not written that way.
    ///
    /// The column is `Decimal(14,4)` — asked, and answered 2026-09-25. That
    /// is a BOUND, not a format: at most four places can ever arrive, and
    /// padding to it would print `2,5000 л/дка` where the operation sheet
    /// says `2,5`. So the fraction length comes from what arrived, which
    /// round-trips exactly.
    ///
    /// ── An empty unit is a MEANING, not a missing value ──
    ///
    /// `doseUnit` is the unit's SYMBOL — `л/дка`, already Bulgarian and
    /// display-ready — and it falls back to an EMPTY STRING rather than to
    /// null when a line has no unit recorded. So empty means "no unit", never
    /// "unit unknown", and a placeholder here would invent an uncertainty the
    /// data does not have. The number is shown alone.
    ///
    /// Interpolating it regardless left a trailing space on every such line,
    /// which is invisible in a diff and visible in a right-aligned column.
    var doseText: String {
        let fraction = doseValue.raw.split(separator: ".").dropFirst().first?.count ?? 0
        let number = doseValue.text(scale: fraction)
        guard let unit = doseUnit.recorded else { return number }
        return "\(number) \(unit)"
    }
}

// MARK: - What was growing there anyway

/// Weeds identified in a parcel on one walk of it.
///
/// ── The two lists are the server's split, not the client's ──
///
/// A client sends ONE `weeds` array mixing catalogue binomials and free
/// text. The SERVER splits it: entries matching its weed catalogue become
/// `weedKeys`, the rest become `otherWeeds`. A client cannot choose which
/// column a value lands in, and that is the point — it is what keeps
/// `weedKeys` countable across years when the free-text half is whatever
/// somebody typed.
///
/// So this model never merges them in storage and always renders them
/// together, which is exactly what the server asks for.
struct WeedObservation: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// Catalogue Latin binomials — the reportable half. Group and count on
    /// these.
    let weedKeys: [String]
    /// Free text for a species the catalogue does not carry.
    let otherWeeds: [String]
    let notes: String?

    let observedAtRaw: String

    enum CodingKeys: String, CodingKey {
        case id, weedKeys, otherWeeds, notes
        case observedAtRaw = "observedAt"
    }

    var observedAt: Date? { BgDate.parseInstantOrDay(observedAtRaw) }

    /// Both halves, in Bulgarian where a Bulgarian name is known, in one
    /// list for display. Catalogue entries first: they are the half that
    /// means the same thing from year to year.
    var displayNames: [String] {
        weedKeys.map(WeedCatalogue.name(for:)) + otherWeeds
    }
}

/// The weed catalogue, as a DISPLAY TABLE and a picker suggestion — never as
/// a validator.
///
/// ── Why this cannot be treated as the truth ──
///
/// The catalogue is the one thing in this feature that the generated spec
/// does NOT pin. `Sorghum halepense` appears exactly once in
/// `openapi.json`, as an `example`; there is no enum, and no endpoint serves
/// the list. So these thirteen were relayed by hand, and the server's real
/// catalogue is a list this client cannot see and cannot verify.
///
/// That is the shape of every contract defect this repo has hit: a declared
/// list that nothing checks against reality. So nothing here decides
/// anything. The server splits `weeds` into keys and free text; this table
/// only answers "what do we call this one in Bulgarian", and its fallback is
/// the binomial itself — so a fourteenth weed added server-side shows up as
/// `Lolium perenne` rather than as a blank, a crash, or a wrong name.
///
/// ── The Bulgarian names want a farmer's eye ──
///
/// They are the standard agronomic names, written here by the client. They
/// are not from the server and not from a translation file, so they are the
/// weakest thing in this file. Wrong is worse than Latin: a farmer acting on
/// «балур» when the row means something else is a real cost. Being asked to
/// confirm.
enum WeedCatalogue {
    /// Binomial → Bulgarian, in the order the catalogue was relayed in.
    /// A `KeyValuePairs` rather than a dictionary so the picker's order is
    /// stable and reviewable.
    static let entries: KeyValuePairs<String, String> = [
        "Sorghum halepense": "балур",
        "Echinochloa crus-galli": "кокоше просо",
        "Setaria viridis": "зелена кощрява",
        "Avena fatua": "див овес",
        "Cynodon dactylon": "троскот",
        "Cirsium arvense": "полска паламида",
        "Convolvulus arvensis": "полска поветица",
        "Chenopodium album": "бяла лобода",
        "Amaranthus retroflexus": "обикновен щир",
        "Sinapis arvensis": "полски синап",
        "Raphanus raphanistrum": "дива ряпа",
        "Papaver rhoeas": "полски мак",
        "Galium aparine": "лепка",
    ]

    /// The binomials, for a picker. NOT for validation — see the header.
    static var binomials: [String] { entries.map(\.key) }

    /// «балур (Sorghum halepense)» for a known one, the binomial verbatim
    /// for anything else.
    ///
    /// The Latin stays alongside the Bulgarian on purpose: it is what the
    /// server stores, what an agronomist's spray label says, and the only
    /// half of the pair this client did not invent.
    static func name(for key: String) -> String {
        guard let bulgarian = entries.first(where: { $0.key == key })?.value else {
            return key
        }
        return "\(bulgarian) (\(key))"
    }
}

// MARK: - The writes

/// A season to record. `year` and `cropType` are the only required fields.
///
/// Back-fillable ON PURPOSE — years long before the farm started using this
/// system are accepted, so the form must not refuse them either. The
/// server's reason is worth keeping: an archive whose earliest entry is
/// today is not an archive.
///
/// NO `Idempotency-Key`. The spec documents the header on six writes —
/// journal create and edit, farm-task, field-operation, task status and the
/// new exchange message send — and documents its ABSENCE where it matters
/// (`POST /locations/:id/parcels`: "a replayed create draws a SECOND
/// parcel"). It says nothing at all about these two, so this client sends
/// none and must not auto-retry: a replay would write a second season.
/// Same discipline as a grain cost — one in-flight write, and a timeout
/// reported as UNKNOWN rather than as failure.
struct NewCropSeason: Encodable, Equatable, Sendable {
    let year: Int
    let cropType: String
    var sownAt: Date?
    var harvestedAt: Date?
    var notes: String?
}

/// Weeds seen on a walk. ONE list, mixing catalogue binomials and free text;
/// the server splits it.
///
/// `weeds` must be non-empty — an observation resolving to nothing is
/// refused, and duplicates collapse server-side. Sending an empty list is a
/// 400 the form should prevent rather than discover.
///
/// No `Idempotency-Key`, for the reason on `NewCropSeason`.
struct NewWeedObservation: Encodable, Equatable, Sendable {
    let observedAt: Date
    let weeds: [String]
    var notes: String?

    /// Trimmed, de-duplicated case-insensitively, and emptied entries
    /// dropped — so the 400 the server would return for "nothing resolvable"
    /// is something the caller can test for before sending.
    ///
    /// Duplicates collapse on the server too. Doing it here as well is not
    /// redundancy: it makes `weeds.isEmpty` an honest submit guard, which it
    /// is not if the array can hold three blanks.
    static func cleaned(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - The whole archive, in one answer

/// `GET /history` — three lists, three cursors, one request.
///
/// ── Why this was not modelled with the item schemas ──
///
/// It was the part still moving. The route answered with the entire archive
/// unbounded, a cap was with the owner, and a client built on that envelope
/// would have been built on the shape expected to change. The items shipped
/// first (2026-09-25), the cap landed the same day, and the screen is now a
/// store and a view over models that already existed. That ordering was the
/// right one and is worth repeating: build against the settled half, and the
/// moving half costs a day rather than a rewrite.
///
/// ── Three cursors, because there is no single position ──
///
/// The sections sort by three different keys — harvest YEAR, completion date,
/// observation date — so there is nothing to page from in common. Each list
/// carries its own cursor, null when that list has no older rows, and each is
/// paged independently: a parcel with 200 operations and 3 crop seasons
/// returns a cursor for the operations only.
///
/// ── Cursors are OPAQUE. Do not parse one. ──
///
/// They happen to be base64url of `<sortKey>|<rowId>`, which the server
/// states so that nobody believes a cursor keeps ids out of a URL — it does
/// not, it encodes one. But the encoding is explicitly NOT a contract, and
/// the reason is specific: `cropSeasonsCursor` keys on an integer YEAR while
/// the other two key on timestamps. A client that parsed and rebuilt one
/// would paginate on a value the `ORDER BY` never uses, which SKIPS ROWS
/// rather than failing — and a short archive looks exactly like a young farm.
struct ParcelHistory: Decodable, Equatable, Sendable {
    let parcel: ParcelRef
    let cropSeasons: [CropSeason]
    let operations: [ParcelHistoryOperation]
    let weedObservations: [WeedObservation]

    /// Null means that list has nothing older. Non-null does NOT guarantee
    /// more rows exist — see `ParcelHistoryStore.Section.exhausted` for why a
    /// client cannot trust it as a "has more" flag.
    let cropSeasonsCursor: String?
    let operationsCursor: String?
    let weedObservationsCursor: String?

    /// The parcel this archive belongs to, as the route projects it.
    struct ParcelRef: Decodable, Equatable, Sendable {
        let id: String
        let name: String

        /// The CURRENT crop, and a single overwritten field.
        ///
        /// It carries no year and no history, which is the entire reason
        /// `cropSeasons` exists. The server is explicit that a client must
        /// not infer this year from here and the rest from the archive: the
        /// archive is the record, and this is a label on the parcel.
        let cropType: String?

        var cropLabel: String? { CommodityName.freeText(cropType) }
    }
}
