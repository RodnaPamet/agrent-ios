import Foundation

/// Uploading parcel boundaries, and the job that parses them.
///
/// ── What the server does with the file, which the warning has to say ──
///
/// TODAY the worker REPLACES the location's parcels. Not merges — swaps the
/// set. There is no undo route. The owner has asked for geometry-matched
/// replacement with history carried across (overlap above a threshold, and an
/// unmatched parcel kept and flagged), and that work is with the server
/// session as an issue. Until it lands, the confirmation names the whole
/// parcel count, because a client that promised "only matching parcels are
/// replaced" against a worker that swaps everything would be the defect this
/// repo has spent a week removing: a declared contract describing something
/// untrue.
///
/// ── Nothing has happened when the POST returns ──
///
/// The parse NEVER runs on the request thread. The handler validates the
/// extension, enforces the byte cap on the DECLARED size before buffering,
/// stages the bytes and queues a job — so the 202 means "accepted", not
/// "imported", and the map must not be refreshed on it.
enum SpatialImportFormat: String, CaseIterable, Sendable {
    case shapefile
    case kml
    case geojson

    /// The extensions the server accepts, lowercased.
    ///
    /// A shapefile is not one file — it is `.shp` plus `.dbf` plus `.shx` and
    /// usually more — which is why the server takes a `.zip` and why a farmer
    /// who picks the bare `.shp` out of a folder has not given it what it
    /// needs. Worth saying on screen rather than letting the server refuse it.
    var extensions: [String] {
        switch self {
        case .shapefile: ["zip"]
        case .kml: ["kml", "kmz"]
        case .geojson: ["geojson", "json"]
        }
    }

    /// FIVE MEGABYTES for a shapefile, TEN for the others.
    ///
    /// Enforced server-side on `file.size` BEFORE the body is buffered, so an
    /// oversized upload is refused without being transferred. Checked here for
    /// the farmer's sake rather than the server's: on a field connection,
    /// discovering a 40 MB file is too big AFTER uploading it is the
    /// difference between a moment and a quarter of an hour.
    var byteCap: Int {
        switch self {
        case .shapefile: 5 * 1024 * 1024
        case .kml, .geojson: 10 * 1024 * 1024
        }
    }

    var capText: String { "\(byteCap / (1024 * 1024)) MB" }

    /// What a `.zip` of shapefile parts is, as far as the wire is concerned.
    /// The server decides the real format from the extension; this only has to
    /// be honest about the bytes.
    var mimeType: String {
        switch self {
        case .shapefile: "application/zip"
        case .kml: "application/vnd.google-earth.kml+xml"
        case .geojson: "application/geo+json"
        }
    }

    var label: String {
        switch self {
        case .shapefile: "Shapefile (.zip)"
        case .kml: "KML / KMZ"
        case .geojson: "GeoJSON"
        }
    }

    /// The format a filename implies, or nil for one the server will refuse.
    static func forFile(named name: String) -> SpatialImportFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }

    /// Every extension, for the document picker.
    static var allExtensions: [String] { allCases.flatMap(\.extensions) }
}

/// Why a chosen file cannot be sent, in words a farmer can act on.
///
/// Checked BEFORE the upload, so a refusal costs a moment rather than a
/// transfer. Each case names what to do, not only what is wrong — «too big»
/// without a cap is a dead end.
enum SpatialImportRefusal: Equatable, Sendable {
    case unsupportedExtension(String)
    case tooLarge(format: SpatialImportFormat, actualBytes: Int)
    case empty

    var text: String {
        switch self {
        case .unsupportedExtension(let ext):
            let kinds = SpatialImportFormat.allCases.map(\.label).joined(separator: ", ")
            return ext.isEmpty
                ? "Файлът няма разширение. Приемат се: \(kinds)."
                : "Файлове «.\(ext)» не се приемат. Приемат се: \(kinds)."
        case .tooLarge(let format, let actual):
            let mb = Double(actual) / (1024 * 1024)
            return "Файлът е \(Num.text(mb)) MB. Максимумът за \(format.label) е \(format.capText)."
        case .empty:
            return "Файлът е празен."
        }
    }
}

extension SpatialImportFormat {
    /// The refusal for this file, or nil when it may be sent.
    ///
    /// Static rather than a method, because the commonest refusal is that
    /// there IS no format — an unsupported extension has no instance to hang a
    /// check on.
    static func refusal(forFile name: String, bytes: Int) -> SpatialImportRefusal? {
        guard let format = forFile(named: name) else {
            return .unsupportedExtension((name as NSString).pathExtension.lowercased())
        }
        if bytes <= 0 { return .empty }
        if bytes > format.byteCap { return .tooLarge(format: format, actualBytes: bytes) }
        return nil
    }
}

// MARK: - The 202

/// The upload was staged and the parse queued. NOTHING HAS BEEN IMPORTED.
struct SpatialImportAccepted: Decodable, Equatable, Sendable {
    let jobId: String
    /// The staged upload, which becomes `Location.spatialFileId` on success.
    let fileRecordId: String
    /// What the server decided the file was, which may not be what the
    /// extension suggested to this client.
    let format: String
    /// Always `queued` per the spec's enum, and read as a string rather than
    /// pinned: a second state appearing here must not fail the upload the
    /// farmer just waited for.
    let status: String
}

// MARK: - The poll

/// A BullMQ job, polled until it stops moving.
///
/// ── `state` is a raw queue state, not a domain enum ──
///
/// The spec documents it as "waiting, active, completed, failed, …" — an open
/// list with an explicit ellipsis. So it is a `String` here and
/// `ImportJobStage` interprets it, rather than an enum that would turn a new
/// queue state into a decode failure on a screen the farmer is watching.
struct ImportJobStatus: Decodable, Equatable, Sendable {
    /// NULLABLE despite being `required` — the key is always present, the
    /// value need not be.
    let jobId: String?
    let state: String
    let failedReason: String?

    /// `progress` and `result` are untyped in the spec (`{}` — any JSON), and
    /// modelling them would be inventing a shape. The counters live in
    /// `result.details` per the description; when a screen needs them, they
    /// get read then, against a real response.
    var stage: ImportJobStage { ImportJobStage(state) }
}

/// What the queue state means for someone standing in a field.
enum ImportJobStage: Equatable, Sendable {
    case waiting
    case running
    case done
    case failed
    /// A state this build has not heard of. Treated as STILL RUNNING rather
    /// than as done: the open list in the spec means new states are expected,
    /// and calling an unknown one "finished" would refresh the map over
    /// parcels the worker is still writing.
    case unknown(String)

    init(_ state: String) {
        switch state.lowercased() {
        case "waiting", "delayed", "paused", "queued": self = .waiting
        case "active": self = .running
        case "completed": self = .done
        case "failed": self = .failed
        default: self = .unknown(state)
        }
    }

    /// Whether polling should continue.
    var isTerminal: Bool {
        switch self {
        case .done, .failed: true
        case .waiting, .running, .unknown: false
        }
    }

    var text: String {
        switch self {
        case .waiting: "На опашка…"
        case .running: "Обработва се…"
        case .done: "Готово."
        case .failed: "Импортът не успя."
        case .unknown: "Обработва се…"
        }
    }
}
