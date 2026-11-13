import Foundation

/// «Машини» (#574, owner 2026-11-09): the farm's machines, tracked by a GPS
/// unit with its own SIM wired to each (a Teltonika FMB920 or FMC130), not an
/// AirTag: Apple has no Find My API for apps. Contract: agri-saas #2948.
///
/// ── Who sees what (owner) ──
///
/// OWNER and ADMIN see every machine, live and its day's route. A
/// MECHANISATOR sees only the machine on their own current task, read under
/// `farm-tasks` (`taskMachinePath`), and is told which machines are tracked
/// and who can see them (`trackedPath`). Nobody's phone is tracked.
///
/// ── 30 days of route, worked parcels for good (owner) ──
///
/// The server keeps a machine's positions 30 days, then only the parcels it
/// worked, for how long and roughly what area. So `/track` past 30 days says
/// `retained: false`, and `/worked` answers for any date.
enum MachinesAPI {
    private static var base: String { "\(FarmPath.root)/machines" }

    static var listPath: String { base }
    /// A Sofia calendar day, `YYYY-MM-DD`, resolved by the server.
    static func trackPath(_ assetID: String, day: String) -> String {
        "\(base)/\(URLEscape.segment(assetID))/track?date=\(day)"
    }
    static func workedPath(_ assetID: String, day: String) -> String {
        "\(base)/\(URLEscape.segment(assetID))/worked?date=\(day)"
    }
    static var trackersPath: String { "\(base)/trackers" }
    static func trackerPath(_ id: String) -> String { "\(trackersPath)/\(URLEscape.segment(id))" }

    /// The machinery register the trackers hang off (`Asset`). Undocumented
    /// on the server (in its route inventory, not its spec), so read here as
    /// leniently as everything else.
    static var assetsPath: String { "\(FarmPath.root)/assets" }

    /// Under `farm-tasks`, the one prefix a MECHANISATOR reaches.
    static var trackedPath: String { "\(FarmPath.root)/farm-tasks/tracked-machines" }
    static func taskMachinePath(_ taskID: String) -> String {
        "\(FarmPath.root)/farm-tasks/\(URLEscape.segment(taskID))/machine"
    }
    static func taskAssetsPath(_ taskID: String) -> String {
        "\(FarmPath.root)/farm-tasks/\(URLEscape.segment(taskID))/assets"
    }
    static func taskAssetPath(_ taskID: String, assetID: String) -> String {
        "\(taskAssetsPath(taskID))/\(URLEscape.segment(assetID))"
    }

    static func machines() async throws -> [Machine] {
        let data = try await APIClient.shared.data(for: listPath)
        return try await APIClient.shared.decode(data, as: MachineList.self).machines
    }

    static func track(_ assetID: String, day: String) async throws -> MachineTrack {
        let data = try await APIClient.shared.data(for: trackPath(assetID, day: day))
        return try await APIClient.shared.decode(data, as: MachineTrack.self)
    }

    static func worked(_ assetID: String, day: String) async throws -> WorkedDay {
        let data = try await APIClient.shared.data(for: workedPath(assetID, day: day))
        return try await APIClient.shared.decode(data, as: WorkedDay.self)
    }

    static func trackers() async throws -> TrackerRegister {
        let data = try await APIClient.shared.data(for: trackersPath)
        return try await APIClient.shared.decode(data, as: TrackerRegister.self)
    }

    static func assets() async throws -> [MachineAsset] {
        let data = try await APIClient.shared.data(for: assetsPath)
        return try await decodeAssets(data)
    }

    /// The list as a bare array or `{ assets: [...] }`: the route is not in
    /// the spec, so both are read rather than one guessed.
    static func decodeAssets(_ data: Data) async throws -> [MachineAsset] {
        if let rows = try? await APIClient.shared.decode(data, as: [Lossy<MachineAsset>].self) {
            return rows.compactMap(\.value)
        }
        return try await APIClient.shared.decode(data, as: AssetList.self).assets
    }

    static func tracked() async throws -> TrackedMachines {
        let data = try await APIClient.shared.data(for: trackedPath)
        return try await APIClient.shared.decode(data, as: TrackedMachines.self)
    }

    static func taskMachine(_ taskID: String) async throws -> TaskMachine {
        let data = try await APIClient.shared.data(for: taskMachinePath(taskID))
        return try await APIClient.shared.decode(data, as: TaskMachine.self)
    }

    // MARK: - Writes (admins; never sent from tests, CI or A11yShots)

    struct NewAsset: Encodable, Sendable {
        let name: String
        let type: String
        let manufacturer: String?
        let model: String?
    }

    static func createAsset(_ asset: NewAsset) async throws -> String {
        let data = try await APIClient.shared.postReturningData(assetsPath, body: asset, idempotencyKey: UUID().uuidString)
        return try await APIClient.shared.decode(data, as: Created.self).id
    }

    struct NewTracker: Encodable, Sendable {
        let assetId: String
        let imei: String
        let label: String?
        /// Must be true: the server refuses a tracker whose drivers were not
        /// told, and stamps who confirmed it and when from the session.
        let driversInformed: Bool
    }

    static func addTracker(_ tracker: NewTracker) async throws {
        _ = try await APIClient.shared.postReturningData(trackersPath, body: tracker, idempotencyKey: UUID().uuidString)
    }

    static func removeTracker(_ id: String) async throws {
        _ = try await APIClient.shared.deleteReturningData(trackerPath(id))
    }

    private struct Created: Decodable { let id: String }
}

/// A list where one bad row costs that row, never the list.
struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// One machine on the live map.
struct Machine: Decodable, Identifiable, Equatable, Sendable {
    let assetId: String
    let name: String
    /// `TRACTOR`, `HARVESTER`, `IMPLEMENT`, `VEHICLE`; a String, so a new one
    /// costs its word, not the machine.
    let type: String?
    /// Null until the source has reported.
    let lastPosition: Position?
    /// Where its position comes from: a tracker box, the maker's own
    /// telematics, or the demo farm's simulator (owner, 2026-11-10). Null:
    /// none at all, which is not the same as one gone quiet.
    var positionSource: PositionSource? = nil

    var id: String { assetId }

    struct Position: Decodable, Equatable, Sendable {
        let lat: Double
        let lon: Double
        let recordedAt: Date?
        let speedKph: Double?
        let ignition: Bool?
        /// Worked out by the server (speed of 1 km/h or more), so the phone
        /// and the web cannot disagree about whether a machine is moving.
        let moving: Bool?

        private enum CodingKeys: String, CodingKey { case lat, lon, recordedAt, speedKph, ignition, moving }
        init(lat: Double, lon: Double, recordedAt: Date?, speedKph: Double?, ignition: Bool?, moving: Bool?) {
            self.lat = lat
            self.lon = lon
            self.recordedAt = recordedAt
            self.speedKph = speedKph
            self.ignition = ignition
            self.moving = moving
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lat = try Coordinate.decode(c, .lat)
            lon = try Coordinate.decode(c, .lon)
            recordedAt = try? c.decodeIfPresent(Date.self, forKey: .recordedAt)
            speedKph = try? c.decodeIfPresent(Double.self, forKey: .speedKph)
            ignition = try? c.decodeIfPresent(Bool.self, forKey: .ignition)
            moving = try? c.decodeIfPresent(Bool.self, forKey: .moving)
        }
    }
}

/// A machine's position source (agri-saas #2948, owner 2026-11-10: the
/// makers' telematics first, an adapter per maker, the SIM tracker as one
/// more, and a simulator on a demo farm only).
struct PositionSource: Decodable, Equatable, Hashable, Sendable {
    /// `TRACKER`, `TELEMATICS`, `SIMULATED`; Strings, so a new one costs its
    /// word, not the machine.
    let kind: String
    /// `JOHN_DEERE`, `CNH`, `CLAAS`, `AGCO`, or null.
    let provider: String?

    var isSimulated: Bool { kind == "SIMULATED" }

    /// «John Deere (JDLink)», «GPS тракер», «Демо данни».
    var label: String {
        switch kind {
        case "TRACKER": return "GPS тракер"
        case "SIMULATED": return "Демо данни"
        case "TELEMATICS":
            switch provider {
            case "JOHN_DEERE": return "John Deere (JDLink)"
            case "CNH": return "Case IH / New Holland (AFS Connect)"
            case "CLAAS": return "CLAAS (CLAAS connect)"
            case "AGCO": return "Fendt / Massey Ferguson (AGCO Connect)"
            default: return "Телематика на производителя"
            }
        default: return "Източник на местоположение"
        }
    }
}

private struct MachineList: Decodable {
    let machines: [Machine]
    private enum CodingKeys: String, CodingKey { case machines }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = ((try? c.decode([Lossy<Machine>].self, forKey: .machines)) ?? []).compactMap(\.value)
    }
}

/// A task's machine for the person on it (agri-saas #2948). With several
/// tracked, the server picks one by a fixed rule (self-propelled before
/// trailed, then the earliest tracker, then the id) and says how many there
/// are, so the screen does not present one of two as the only one.
struct TaskMachine: Decodable, Equatable, Sendable {
    /// The machine shown, for the alert's own link (`/t/{slug}/machines/{assetId}`).
    var assetId: String? = nil
    var type: String? = nil
    let name: String?
    let lastPosition: Machine.Position?
    /// How many of the task's machines have a position source.
    let locatableCount: Int?

    private enum CodingKeys: String, CodingKey { case assetId, type, name, lastPosition, locatableCount }
    init(name: String?, lastPosition: Machine.Position?, locatableCount: Int?) {
        self.name = name
        self.lastPosition = lastPosition
        self.locatableCount = locatableCount
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try? c.decodeIfPresent(String.self, forKey: .assetId)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        lastPosition = try? c.decodeIfPresent(Machine.Position.self, forKey: .lastPosition)
        locatableCount = try? c.decodeIfPresent(Int.self, forKey: .locatableCount)
    }
}

/// One day's route, oldest point first.
struct MachineTrack: Decodable, Equatable, Sendable {
    let date: String
    let points: [Point]
    /// The server stopped at its cap: a cut route would read as a machine
    /// that stopped, so the screen says so.
    let truncated: Bool
    /// False past 30 days: the route is no longer kept. Not "did not move".
    let retained: Bool

    struct Point: Decodable, Equatable, Sendable {
        let lat: Double
        let lon: Double
        let recordedAt: Date?
        let speedKph: Double?
        let ignition: Bool?

        private enum CodingKeys: String, CodingKey { case lat, lon, recordedAt, speedKph, ignition }
        init(lat: Double, lon: Double, recordedAt: Date?, speedKph: Double?, ignition: Bool?) {
            self.lat = lat
            self.lon = lon
            self.recordedAt = recordedAt
            self.speedKph = speedKph
            self.ignition = ignition
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lat = try Coordinate.decode(c, .lat)
            lon = try Coordinate.decode(c, .lon)
            recordedAt = try? c.decodeIfPresent(Date.self, forKey: .recordedAt)
            speedKph = try? c.decodeIfPresent(Double.self, forKey: .speedKph)
            ignition = try? c.decodeIfPresent(Bool.self, forKey: .ignition)
        }
    }

    private enum CodingKeys: String, CodingKey { case date, points, truncated, retained }

    /// Stable: equal or missing times keep the order they came in.
    static func chronological(_ points: [Point]) -> [Point] {
        points.enumerated().sorted { a, b in
            switch (a.element.recordedAt, b.element.recordedAt) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
    init(date: String, points: [Point], truncated: Bool = false, retained: Bool = true) {
        self.date = date
        self.points = points
        self.truncated = truncated
        self.retained = retained
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        // In the order the DEVICE recorded them: a tracker out of signal
        // buffers and replays later, so arrival order is not the route's
        // (agri-saas #2948 stage 2). A point without a time keeps its place.
        points = Self.chronological(((try? c.decode([Lossy<Point>].self, forKey: .points)) ?? []).compactMap(\.value))
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        retained = (try? c.decodeIfPresent(Bool.self, forKey: .retained)) ?? true
    }
}

/// The parcels a machine worked on a day, from the server's nightly
/// derivation (`WorkedParcel`), so today's appear tomorrow.
struct WorkedDay: Decodable, Equatable, Sendable {
    let date: String
    let parcels: [Parcel]
    /// Whether the night's derivation has run for this day: null means not
    /// yet, a time means it ran (and an empty list is then a real «nothing
    /// worked»). Nil when the server did not say, from before the field.
    let derived: Bool?

    struct Parcel: Decodable, Equatable, Sendable, Identifiable {
        let parcelId: String
        let name: String
        let minutesWorked: Int
        let areaHa: Double?
        /// 0…1: a weak match is offered as a suggestion, not a fact.
        let confidence: Double?
        var id: String { parcelId }
    }

    private enum CodingKeys: String, CodingKey { case date, parcels, derivedAt }
    init(date: String, parcels: [Parcel], derived: Bool? = nil) {
        self.date = date
        self.parcels = parcels
        self.derived = derived
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        parcels = ((try? c.decode([Lossy<Parcel>].self, forKey: .parcels)) ?? []).compactMap(\.value)
        if c.contains(.derivedAt) {
            derived = !((try? c.decodeNil(forKey: .derivedAt)) ?? true)
        } else {
            derived = nil
        }
    }
}

/// The admin's register: each tracker, and what to type into the device.
struct TrackerRegister: Decodable, Equatable, Sendable {
    /// Where the devices report. Null when the server has none set up: the
    /// screen says so rather than leaving a blank to type in.
    let ingest: Ingest?
    let trackers: [Tracker]

    struct Ingest: Decodable, Equatable, Sendable {
        let host: String
        let port: Int
        let protocolName: String?
        private enum CodingKeys: String, CodingKey { case host, port, protocolName = "protocol" }
    }

    struct Tracker: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let assetId: String
        let assetName: String?
        let assetType: String?
        let imei: String
        let label: String?
        let installedAt: Date?
        let driversInformedAt: Date?
        let driversInformedByName: String?
        let lastSeenAt: Date?
    }

    private enum CodingKeys: String, CodingKey { case ingest, trackers }
    init(ingest: Ingest?, trackers: [Tracker]) {
        self.ingest = ingest
        self.trackers = trackers
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ingest = try? c.decodeIfPresent(Ingest.self, forKey: .ingest)
        trackers = ((try? c.decode([Lossy<Tracker>].self, forKey: .trackers)) ?? []).compactMap(\.value)
    }
}

/// A machine in the farm's register (`Asset`).
struct MachineAsset: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let type: String?
    /// On a task's list (agri-saas #2948): where its position comes from, so
    /// the task says which of its machines can be found.
    var positionSource: PositionSource? = nil
    /// Whether the server said either way: only then is no source «без
    /// източник на местоположение» rather than unknown.
    var sourceKnown = false

    /// Only machines can carry a tracker; the register also holds buildings,
    /// storage and tools.
    var isMachine: Bool { MachineKind(rawValue: type ?? "") != nil }

    init(id: String, name: String, type: String?) {
        self.id = id
        self.name = name
        self.type = type
    }

    /// `id` in the register, `assetId` where a task names its machines: the
    /// task's list is not in the spec yet, so either is read.
    private enum CodingKeys: String, CodingKey { case id, assetId, name, type, assetName, assetType, positionSource }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? (try? c.decodeIfPresent(String.self, forKey: .assetId)),
              let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (try? c.decodeIfPresent(String.self, forKey: .assetName))
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "an asset with no id or name"))
        }
        self.id = id
        self.name = name
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? (try? c.decodeIfPresent(String.self, forKey: .assetType))
        positionSource = try? c.decodeIfPresent(PositionSource.self, forKey: .positionSource)
        sourceKnown = c.contains(.positionSource)
    }
}

private struct AssetList: Decodable {
    let assets: [MachineAsset]
    private enum CodingKeys: String, CodingKey { case assets, items, machines }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decode([Lossy<MachineAsset>].self, forKey: .assets))
            ?? (try? c.decode([Lossy<MachineAsset>].self, forKey: .items))
            ?? (try? c.decode([Lossy<MachineAsset>].self, forKey: .machines)) ?? []
        assets = rows.compactMap(\.value)
    }
}

/// For a mechanisator: which machines are tracked, and who sees them.
struct TrackedMachines: Decodable, Equatable, Sendable {
    let machines: [Named]
    /// From the server, so a change to who may see reaches this notice too.
    let visibleTo: [String]

    struct Named: Decodable, Equatable, Sendable {
        let name: String
        let type: String?
    }

    private enum CodingKeys: String, CodingKey { case machines, visibleTo }
    init(machines: [Named], visibleTo: [String]) {
        self.machines = machines
        self.visibleTo = visibleTo
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = ((try? c.decode([Lossy<Named>].self, forKey: .machines)) ?? []).compactMap(\.value)
        visibleTo = (try? c.decodeIfPresent([String].self, forKey: .visibleTo)) ?? []
    }
}

/// The four kinds of machine a tracker goes on, in Bulgarian.
enum MachineKind: String, CaseIterable, Identifiable, Sendable {
    case tractor = "TRACTOR"
    case harvester = "HARVESTER"
    case implement = "IMPLEMENT"
    case vehicle = "VEHICLE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tractor: "Трактор"
        case .harvester: "Комбайн"
        case .implement: "Прикачен инвентар"
        case .vehicle: "Автомобил"
        }
    }

    /// The word for any kind the fleet list can carry. It also returns
    /// `IRRIGATION` (a pivot with its own position source, agri-saas #2948),
    /// which is named but not offered when adding a tracker.
    static func label(_ raw: String?) -> String? {
        if raw == "IRRIGATION" { return "Напоителна система" }
        return raw.flatMap(MachineKind.init(rawValue:))?.label
    }
}

/// A tracker's IMEI: 15 digits with a Luhn check digit, so a typo is caught
/// on the phone before the server refuses it. Pure, so tests pin it.
enum IMEI {
    /// Digits only, spaces and dashes dropped (labels print it in groups).
    static func normalised(_ text: String) -> String {
        text.filter { $0 != " " && $0 != "-" }
    }

    static func isValid(_ text: String) -> Bool {
        let digits = normalised(text)
        guard digits.count == 15, digits.allSatisfy(\.isASCIIDigit) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            var value = Int(String(character)) ?? 0
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// A coordinate as the server sends it: a decimal STRING («"43.4120000"»,
/// `Decimal(10,7)`, agri-saas #2948 stage 3), so equal coordinates stay
/// equal server-side. Read here as a number for the map only; the phone
/// never sends one back. A plain number is accepted too.
enum Coordinate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Double {
        if let text = try? c.decode(String.self, forKey: key),
           let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite {
            return value
        }
        return try c.decode(Double.self, forKey: key)
    }
}
