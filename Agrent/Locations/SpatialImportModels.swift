import Foundation

/// Uploading parcel boundaries, and the job that parses them.
///
/// ── What the server does with the file, which the warning has to say ──
///
/// THE WORKER RECONCILES BY GEOMETRY, since agri-saas#1135:
///
///     IoU >= 0.90   the existing parcel is UPDATED in place — same row,
///                   same id, so its history follows the new boundary
///     no match      INSERTED
///     not in file   KEPT and flagged with `absentFromImportAt`
///
/// Nothing is deleted at any point, which is what makes a re-import safe to
/// run twice. It was not.
///
/// THIS SENTENCE HAS BEEN WRONG TWICE, in opposite directions, and both times
/// it was wrong in the repo rather than in anyone's head. It first said the
/// worker REPLACES the set — quoted from a route description — and a
/// confirmation reading «Ще замени 14 парцела» was two hours from shipping.
/// The worker was in fact additive, which its own docblock said while the
/// route description said otherwise. The copy was corrected to warn about
/// duplicates, and then #1135 made THAT wrong. This header was left saying
/// "replaces" through both corrections.
///
/// So the rule the third version follows: the screen promises only what is
/// true of every file, and the numbers come from the job AFTERWARDS. A
/// pre-upload sheet cannot know the split before the server has parsed
/// anything, and a promise it cannot keep is how the first two versions went
/// wrong.
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
/// THE EXECUTOR'S RETURN VALUE, shared by two job kinds.
///
/// ── Why `details` is decoded with `try?` ──
///
/// On the wire `details` is `{}` — untyped — because `spatial-import` and
/// `cadastre-import` share this envelope and a `$ref` to either one's shape
/// would over-claim for the other. The server registers
/// `SpatialImportDetails` separately for exactly this reason: nothing
/// `$ref`s it, and reading it is the client's choice.
///
/// So this app polls both kinds through one type, and a cadastre envelope's
/// `details` does not carry `matched`/`created`/`flagged`. Decoding it
/// strictly would fail the WHOLE poll response — on the screen a farmer is
/// watching an import finish. A missing summary is a worse screen; a failed
/// poll is a broken one.
///
/// The cost is stated rather than hidden: `try?` also swallows a genuine
/// spatial-import shape change. The tolerance probe is what catches that,
/// against the published `required` list, which is why both models are in it.
struct JobRunEnvelope: Decodable, Equatable, Sendable {
    let jobName: String
    let jobRunId: String
    let success: Bool
    let itemsScanned: Int
    let itemsActioned: Int
    let itemsSkipped: Int

    /// `details` read as the spatial shape, or nil when it is another job's.
    let spatial: SpatialImportDetails?

    /// `startedAt`, `completedAt`, `durationMs` and `errorMessage` are on the
    /// wire and are not read here. Nothing on this screen shows them —
    /// `failedReason` already carries why a job failed — and a field modelled
    /// for its own sake is a field that can fail a payload for its own sake.
    enum CodingKeys: String, CodingKey {
        case jobName, jobRunId, success
        case itemsScanned, itemsActioned, itemsSkipped
        case details
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobName = try c.decode(String.self, forKey: .jobName)
        jobRunId = try c.decode(String.self, forKey: .jobRunId)
        success = try c.decode(Bool.self, forKey: .success)
        itemsScanned = try c.decode(Int.self, forKey: .itemsScanned)
        itemsActioned = try c.decode(Int.self, forKey: .itemsActioned)
        itemsSkipped = try c.decode(Int.self, forKey: .itemsSkipped)
        spatial = try? c.decodeIfPresent(SpatialImportDetails.self, forKey: .details)
    }
}

/// WHAT THE RECONCILIATION DID, in three numbers.
///
/// ── The one arithmetic rule ──
///
/// `parcelCount == matched + created` — the shapes the FILE contained — and
/// `flagged` is deliberately NOT part of it. Flagged parcels were already
/// there and the file did not mention them, so adding them to a total called
/// "imported" would report more than arrived.
///
/// ── These three did not exist on the wire a day ago ──
///
/// They were described to this app as available and were not: the worker
/// returned them, and the executor that builds `details` dropped them before
/// they reached the poll route. Nothing caught it on either side — `details`
/// is `Record<string, unknown>` so the compiler was happy, and the server's
/// shape ratchet was happy because the operation DOES describe a response.
/// It was found only because this app declined to model three field names
/// from a message. agri-saas#1137 put them on the contract.
///
/// `bounds` is on the wire and is not modelled: untyped AND optional, which
/// is the one combination that has cost this repo a screen twice.
struct SpatialImportDetails: Decodable, Equatable, Sendable {
    /// Matched an existing parcel above the IoU threshold and updated it in
    /// place, so that parcel's history followed its new boundary.
    let matched: Int
    /// Had no match and were inserted.
    let created: Int
    /// Were already there, were not in the file, and were KEPT.
    let flagged: Int
    /// `matched + created`. Read rather than computed, because the server
    /// owns the definition and a client that recomputes it is a second
    /// description of one thing.
    let parcelCount: Int
}

struct ImportJobStatus: Decodable, Equatable, Sendable {
    /// NULLABLE despite being `required` — the key is always present, the
    /// value need not be.
    let jobId: String?
    let state: String
    let failedReason: String?

    /// OPTIONAL, although `result` is in the spec's `required` list.
    ///
    /// `JobRunEnvelope` is `{"type": ["object", "null"]}` in its own schema,
    /// so a `$ref` to it admits null even where the property is required —
    /// the key is always present and the value is null until the job
    /// completes. `DashboardModels` records getting exactly this wrong once,
    /// with `FieldBriefing`, and that note is why this one is optional.
    let result: JobRunEnvelope?

    /// `progress` is still untyped in the spec (`{}` — any JSON) and is still
    /// not modelled. `result` no longer is: #1137 gave it a `$ref` to
    /// `JobRunEnvelope`, which is what made the counts readable.
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
