import XCTest
@testable import Agrent

/// Uploading parcel boundaries: what may be sent, and what the job says.
final class SpatialImportTests: XCTestCase {

    // MARK: - Which file, and whether it may be sent

    /// A shapefile is not one file — `.shp` plus `.dbf` plus `.shx` at least —
    /// which is why the server takes a `.zip`. A farmer who picks the bare
    /// `.shp` out of a folder has not given it what it needs, and finding that
    /// out from a rejected upload on a field connection is the slow way.
    func testTheAcceptedExtensionsAreRecognised() {
        XCTAssertEqual(SpatialImportFormat.forFile(named: "polya.zip"), .shapefile)
        XCTAssertEqual(SpatialImportFormat.forFile(named: "polya.kml"), .kml)
        XCTAssertEqual(SpatialImportFormat.forFile(named: "polya.kmz"), .kml)
        XCTAssertEqual(SpatialImportFormat.forFile(named: "polya.geojson"), .geojson)
        XCTAssertEqual(SpatialImportFormat.forFile(named: "polya.json"), .geojson)

        // A picker hands back whatever the filesystem has, and macOS and iOS
        // both produce upper-case extensions from some sources.
        XCTAssertEqual(SpatialImportFormat.forFile(named: "POLYA.ZIP"), .shapefile)
        XCTAssertEqual(SpatialImportFormat.forFile(named: "Долен блок.GeoJSON"), .geojson)

        XCTAssertNil(SpatialImportFormat.forFile(named: "polya.shp"),
                     "the bare shapefile part, which the server refuses")
        XCTAssertNil(SpatialImportFormat.forFile(named: "polya"))
    }

    /// FIVE MB for a shapefile and TEN for the others — the server enforces
    /// these on the declared size before buffering, so an oversized file is
    /// refused without being transferred. Checked here so the refusal costs a
    /// moment instead of a quarter of an hour on a field connection.
    func testTheByteCapsAreTheServersAndDifferByFormat() {
        XCTAssertEqual(SpatialImportFormat.shapefile.byteCap, 5 * 1024 * 1024)
        XCTAssertEqual(SpatialImportFormat.kml.byteCap, 10 * 1024 * 1024)
        XCTAssertEqual(SpatialImportFormat.geojson.byteCap, 10 * 1024 * 1024)

        // AT the cap is allowed; one byte over is not. The server compares
        // against the same number, so an off-by-one here would refuse a file
        // it would have accepted.
        XCTAssertNil(SpatialImportFormat.refusal(
            forFile: "a.zip", bytes: 5 * 1024 * 1024))
        XCTAssertEqual(
            SpatialImportFormat.refusal(forFile: "a.zip", bytes: 5 * 1024 * 1024 + 1),
            .tooLarge(format: .shapefile, actualBytes: 5 * 1024 * 1024 + 1))

        // And a GeoJSON of the same size is fine, which is the whole reason
        // the cap is per format rather than one number.
        XCTAssertNil(SpatialImportFormat.refusal(
            forFile: "a.geojson", bytes: 6 * 1024 * 1024))
    }

    func testAnEmptyOrUnsupportedFileIsRefusedBeforeUpload() {
        XCTAssertEqual(SpatialImportFormat.refusal(forFile: "a.zip", bytes: 0), .empty)
        XCTAssertEqual(SpatialImportFormat.refusal(forFile: "a.shp", bytes: 100),
                       .unsupportedExtension("shp"))
        XCTAssertEqual(SpatialImportFormat.refusal(forFile: "noext", bytes: 100),
                       .unsupportedExtension(""))
    }

    /// A refusal names what to do, not only what is wrong. «Too big» without a
    /// cap is a dead end, and a farmer cannot guess which extensions are
    /// accepted.
    func testARefusalSaysWhatIsAcceptedOrWhatTheCapIs() {
        let wrongKind = SpatialImportRefusal.unsupportedExtension("shp").text
        XCTAssertTrue(wrongKind.contains(".shp"), wrongKind)
        XCTAssertTrue(wrongKind.contains("Shapefile"), wrongKind)
        XCTAssertTrue(wrongKind.contains("GeoJSON"), wrongKind)

        let tooBig = SpatialImportRefusal
            .tooLarge(format: .shapefile, actualBytes: 7 * 1024 * 1024).text
        XCTAssertTrue(tooBig.contains("5 MB"), tooBig)
        XCTAssertTrue(tooBig.contains("7"), tooBig)
    }

    // MARK: - The 202, which is not an import

    func testTheAcceptedResponseDecodes() async throws {
        let accepted = try await APIClient.shared.decode(Data(#"""
        {"jobId":"job_1","fileRecordId":"file_9","format":"shapefile","status":"queued"}
        """#.utf8), as: SpatialImportAccepted.self)
        XCTAssertEqual(accepted.jobId, "job_1")
        XCTAssertEqual(accepted.fileRecordId, "file_9")
        XCTAssertEqual(accepted.format, "shapefile")
    }

    // MARK: - The poll

    /// `jobId` is `["string","null"]` while being in `required` — the key is
    /// always present, the value need not be. Non-optional it would have
    /// thrown on the poll a farmer is watching.
    func testAJobStatusWithANullIdDecodes() async throws {
        let status = try await APIClient.shared.decode(Data(#"""
        {"jobId":null,"state":"waiting","failedReason":null}
        """#.utf8), as: ImportJobStatus.self)
        XCTAssertNil(status.jobId)
        XCTAssertEqual(status.stage, .waiting)
    }

    func testTheQueueStatesMapToSomethingAFarmerCanRead() {
        XCTAssertEqual(ImportJobStage("waiting"), .waiting)
        XCTAssertEqual(ImportJobStage("delayed"), .waiting)
        XCTAssertEqual(ImportJobStage("active"), .running)
        XCTAssertEqual(ImportJobStage("completed"), .done)
        XCTAssertEqual(ImportJobStage("failed"), .failed)
    }

    /// THE ONE THAT MATTERS. The spec documents the state list with an
    /// explicit ellipsis — "waiting, active, completed, failed, …" — so new
    /// states are expected.
    ///
    /// An unknown state counts as STILL RUNNING, never as finished. Treating
    /// it as terminal would stop the poll and refresh the map over parcels the
    /// worker is still writing, which is the one outcome worse than waiting.
    func testAnUnknownQueueStateIsNotTreatedAsFinished() {
        let unknown = ImportJobStage("prioritized")
        XCTAssertEqual(unknown, .unknown("prioritized"))
        XCTAssertFalse(unknown.isTerminal, "polling must continue")
        XCTAssertEqual(unknown.text, ImportJobStage.running.text,
                       "and it reads as work in progress")

        XCTAssertTrue(ImportJobStage.done.isTerminal)
        XCTAssertTrue(ImportJobStage.failed.isTerminal)
        XCTAssertFalse(ImportJobStage.waiting.isTerminal)
    }

    // MARK: - The server's refusals (agri-saas #1633)

    /// A refusal body as the farmer reads it.
    private func said(_ status: Int, _ json: String) -> String {
        let env = APIClient.envelope(from: Data(json.utf8))
        return UserMessage.text(for: APIClient.APIError.http(
            status: status, code: env?.code, message: env?.message, params: env?.params))
    }

    /// Every refusal on these routes is coded, and each is said in Bulgarian.
    /// The bodies are the server's own, from #1633's handlers.
    func testEachRefusalIsSaidInBulgarian() {
        XCTAssertEqual(
            said(400, #"{"error":{"code":"FILE_REQUIRED","message":"No file was included in the form data."}}"#),
            "Файлът не стигна до сървъра. Изберете го и опитайте отново.")
        XCTAssertEqual(
            said(400, #"{"error":{"code":"FILE_EMPTY","message":"The uploaded file has no content."}}"#),
            "Файлът е празен.")
        XCTAssertEqual(
            said(415, #"{"error":{"code":"UNSUPPORTED_FILE_TYPE","message":"Upload a shapefile (.zip), KML (.kml/.kmz), or GeoJSON (.geojson/.json).","params":{"allowed":".zip .kml .kmz .geojson .json"}}}"#),
            "Този тип файл не се приема. Приемат се: .zip, .kml, .kmz, .geojson, .json.")
        XCTAssertEqual(
            said(404, #"{"error":{"code":"IMPORT_JOB_NOT_FOUND","message":"No such import job."}}"#),
            "Сървърът не намира това импортиране. Качете файла отново.")
    }

    /// THE ONE A FARMER QUOTED, «File exceeds the 5 MB limit». The numbers
    /// arrive formatted for English, with a point and «5.0» for five, and are
    /// said again the Bulgarian way, in the sentence the phone's own check
    /// uses.
    func testTheSizeRefusalIsSaidWithTheServersNumbers() {
        let text = said(413, #"{"error":{"code":"SPATIAL_UPLOAD_TOO_LARGE","message":"Spatial file is too large (7.2 MB; shapefile limit is 5.0 MB). Simplify or split the upload.","params":{"size":"7.2 MB","limit":"5.0 MB","format":"shapefile"}}}"#)
        XCTAssertEqual(text, "Файлът е 7,2 MB. Максимумът за Shapefile (.zip) е 5 MB.")
        XCTAssertEqual(
            text,
            SpatialImportRefusal.tooLarge(format: .shapefile, actualBytes: 7_549_747).text,
            "one sentence, whichever side refused the file")

        // The follow-up's form: whole bytes, nothing to parse. Same sentence.
        XCTAssertEqual(
            said(413, #"{"error":{"code":"SPATIAL_UPLOAD_TOO_LARGE","params":{"sizeBytes":7549747,"limitBytes":5242880,"format":"shapefile"}}}"#),
            text)

        // A format this build does not know still gets the numbers.
        XCTAssertEqual(
            said(413, #"{"error":{"code":"SPATIAL_UPLOAD_TOO_LARGE","params":{"size":"12.5 MB","limit":"10.0 MB","format":"gpx"}}}"#),
            "Файлът е 12,5 MB. Максимумът е 10 MB.")
    }

    /// A figure that is not plainly megabytes is not quoted at all: «512.0
    /// KB» read as 512 MB would be a wrong sentence, which is worse than a
    /// general one.
    func testAFigureThatIsNotMegabytesIsNotQuoted() {
        let general = "Файлът е твърде голям. Опростете го или го разделете на части."
        XCTAssertEqual(
            said(413, #"{"error":{"code":"SPATIAL_UPLOAD_TOO_LARGE","params":{"size":"512.0 KB","limit":"5.0 MB","format":"shapefile"}}}"#),
            general)
        XCTAssertEqual(
            said(413, #"{"error":{"code":"SPATIAL_UPLOAD_TOO_LARGE","message":"Spatial file is too large."}}"#),
            general)
        XCTAssertEqual(
            said(415, #"{"error":{"code":"UNSUPPORTED_FILE_TYPE"}}"#),
            "Този тип файл не се приема.")
    }

    /// The bare form is still READ, since the auth routes send it, but a bare
    /// string is a code, and a code is never printed. Were one of these
    /// routes to answer bare again, the farmer would get the status sentence
    /// rather than English: the trade #271 chose.
    func testABareSentenceIsNotShownVerbatim() {
        let text = said(400, #"{"error":"Missing or invalid file in form data"}"#)
        XCTAssertEqual(text, UserMessage.statusText(400))
        XCTAssertFalse(text.contains("Missing"), text)
    }

    // MARK: - A job that failed after the 202 (agri-saas #1637)

    private func failed(_ code: String, _ params: String = "null",
                        reason: String = "Import is too complex (812340 vertices across all parcels; limit is 500000).") throws -> ImportJobStatus {
        let json = #"{"jobId":"j","state":"failed","result":null,"failedReason":""# + reason
            + #"","failedCode":"# + code + #","failedParams":"# + params + "}"
        return try JSONDecoder().decode(ImportJobStatus.self, from: Data(json.utf8))
    }

    /// Each code a boundary upload can fail with, said from its numbers.
    /// The worker's English is beside it on the wire and never shown.
    func testEachJobFailureIsSaidInBulgarian() throws {
        let cases: [(String, String, String)] = [
            (#""SPATIAL_PARSE_TIMEOUT""#, #"{"seconds":30}"#,
             "Файлът се обработваше твърде дълго (над 30 секунди). Опростете го или го разделете на части и го качете отново."),
            (#""SPATIAL_TOO_MANY_PARCELS""#, #"{"count":12000,"limit":10000}"#,
             "Файлът съдържа 12 000 парцела, а максимумът е 10 000. Разделете го на части."),
            (#""SPATIAL_PARCEL_TOO_COMPLEX""#, #"{"vertices":61000,"limit":50000}"#,
             "Един от парцелите има 61 000 точки по границата, а максимумът е 50 000. Опростете геометрията и качете файла отново."),
            (#""SPATIAL_IMPORT_TOO_COMPLEX""#, #"{"vertices":812340,"limit":500000}"#,
             "Границите във файла имат общо 812 340 точки, а максимумът е 500 000. Опростете геометрията или разделете файла на части."),
            (#""SPATIAL_GEOMETRY_UNPARSEABLE""#, "null",
             "Границите във файла не могат да бъдат прочетени. Проверете файла и го качете отново."),
            (#""SPATIAL_GEOMETRY_INVALID""#, #"{"count":3}"#,
             "3 парцела са с невалидна геометрия (пресичащи се граници). Поправете ги и качете файла отново."),
            (#""SPATIAL_GEOMETRY_INVALID""#, #"{"count":1}"#,
             "1 парцел е с невалидна геометрия (пресичаща се граница). Поправете го и качете файла отново."),
            (#""SPATIAL_SOURCE_CRS_UNRESOLVED""#, "null",
             "Координатната система на файла не може да се определи. Експортирайте слоя в WGS84 (EPSG:4326) или добавете файла .prj и качете отново."),
            (#""SPATIAL_IMPORT_INTERNAL""#, "null", SpatialJobFailure.serverFault),
        ]
        for (code, params, expected) in cases {
            let text = try failed(code, params).failureText
            // The thousands separator is bg_BG's, which is not a plain space.
            XCTAssertEqual(text.replacingOccurrences(of: "\u{00A0}", with: " ")
                               .replacingOccurrences(of: "\u{202F}", with: " "),
                           expected, code)
        }
    }

    /// Numbers the phone cannot read cost the numbers, never the poll.
    func testUnreadableParamsStillGiveASentence() throws {
        let noNumbers = try failed(#""SPATIAL_IMPORT_TOO_COMPLEX""#, #"["not","an","object"]"#)
        XCTAssertEqual(noNumbers.failedCode, "SPATIAL_IMPORT_TOO_COMPLEX")
        XCTAssertEqual(noNumbers.failureText,
                       "Границите във файла са твърде сложни. Опростете геометрията или разделете файла на части.")
        XCTAssertEqual(try failed(#""SPATIAL_GEOMETRY_INVALID""#, #"{"count":"many"}"#).failureText,
                       "Някои парцели са с невалидна геометрия (пресичащи се граници). Поправете ги и качете файла отново.")
    }

    /// A code this build does not know: the English reason, which knows
    /// something this build does not. No code at all is a crash, whose
    /// reason is not for a farmer.
    func testAnUnknownCodeFallsBackAndACrashDoesNot() throws {
        let newer = try failed(#""SPATIAL_SOMETHING_NEW""#, reason: "The layer has no polygons.")
        XCTAssertEqual(newer.failureText, "The layer has no polygons.")

        let crash = try failed("null", reason: "connect ECONNREFUSED 10.0.0.5:6379")
        XCTAssertNil(crash.failedCode)
        XCTAssertEqual(crash.failureText, SpatialJobFailure.serverFault)

        // A server before #1637 sends neither field, and the poll still reads.
        let old = try JSONDecoder().decode(ImportJobStatus.self, from: Data(
            #"{"jobId":"j","state":"failed","result":null,"failedReason":"Too many parcels."}"#.utf8))
        XCTAssertNil(old.failedCode)
        XCTAssertNil(old.failedParams)
    }

    // MARK: - The body on the wire

    /// Multipart fails silently when it fails: a missing CRLF or a mis-spelled
    /// disposition gives a 400 that names nothing, and this suite has no seam
    /// to observe an outgoing request. So the framing is asserted directly.
    func testTheMultipartBodyIsFramedCorrectly() throws {
        let body = APIClient.multipartBody(
            boundary: "B", file: Data([0x50, 0x4B, 0x03, 0x04]),
            fileName: "Долен блок.zip", mimeType: "application/zip",
            fields: ["cropType": "Пшеница"])
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("--B\r\n"), text.prefix(40).description)
        XCTAssertTrue(text.contains("name=\"cropType\"\r\n\r\nПшеница\r\n"), text)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"Долен блок.zip\""), text)
        XCTAssertTrue(text.contains("Content-Type: application/zip\r\n\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"), String(text.suffix(20)))

        // The file's bytes survive intact — a zip is arbitrary binary and the
        // header is `PK\x03\x04`.
        XCTAssertTrue(body.range(of: Data([0x50, 0x4B, 0x03, 0x04])) != nil)
    }

    /// Fields are SORTED, because dictionary order is not stable across runs
    /// and a body that differs between two identical calls is untestable.
    func testFieldOrderIsStable() {
        let first = APIClient.multipartBody(
            boundary: "B", file: Data(), fileName: "a.zip", mimeType: "application/zip",
            fields: ["b": "2", "a": "1", "c": "3"])
        for _ in 0..<20 {
            XCTAssertEqual(APIClient.multipartBody(
                boundary: "B", file: Data(), fileName: "a.zip",
                mimeType: "application/zip",
                fields: ["c": "3", "a": "1", "b": "2"]), first)
        }
    }

    // MARK: - Paths

    func testThePathsMatchTheSpec() {
        XCTAssertTrue(SpatialImportAPI.uploadPath(locationID: "loc1")
            .hasSuffix("/locations/loc1/spatial-import"))
        XCTAssertTrue(SpatialImportAPI.jobPath(locationID: "loc1", jobID: "j2")
            .hasSuffix("/locations/loc1/spatial-import/j2"))
    }
}


/// The envelope two job kinds share, and the `try?` that lets them.
///
/// The tolerance probe next door asks what a model refuses to decode WITHOUT
/// a key. It cannot ask the question this class asks, which is what happens
/// when a key is PRESENT and holds another job's shape — and that is the
/// case this app actually meets, because it polls `spatial-import` and
/// `cadastre-import` through one type.
@MainActor
final class JobRunEnvelopeTests: XCTestCase {

    private func envelope(details: String) async throws -> JobRunEnvelope {
        let json = """
        {"jobName":"spatial-import","jobRunId":"r","success":true,
         "startedAt":"2026-09-26T10:00:00.000Z",
         "completedAt":"2026-09-26T10:00:04.000Z","durationMs":4000,
         "itemsScanned":1,"itemsActioned":1,"itemsSkipped":0,
         "details":\(details)}
        """
        return try await APIClient.shared.decode(Data(json.utf8), as: JobRunEnvelope.self)
    }

    func testTheSpatialShapeIsRead() async throws {
        let e = try await envelope(details: """
        {"tenantId":"t","locationId":"l","fileRecordId":"f","format":"kml",
         "parcelCount":14,"matched":11,"created":3,"flagged":2,"jobRunId":"r"}
        """)
        XCTAssertEqual(e.spatial?.matched, 11)
        XCTAssertEqual(e.spatial?.created, 3)
        XCTAssertEqual(e.spatial?.flagged, 2)
        XCTAssertEqual(e.spatial?.parcelCount, 14)
    }

    /// THE ONE THAT MATTERS. A cadastre job's `details` has none of the
    /// counts. Decoded strictly it would fail the whole poll response — on
    /// the screen a farmer is watching an import finish.
    func testAnotherJobKindsDetailsDoesNotFailThePoll() async throws {
        let e = try await envelope(details: """
        {"tenantId":"t","locationId":"l","kaisIdentifier":"15655.19","jobRunId":"r"}
        """)
        XCTAssertNil(e.spatial)
        XCTAssertEqual(e.jobName, "spatial-import")
        XCTAssertEqual(e.itemsScanned, 1)
    }

    func testAbsentAndNullDetailsAreBothToleratedRatherThanEitherThrowing() async throws {
        let nullDetails = try await envelope(details: "null")
        XCTAssertNil(nullDetails.spatial)

        let json = """
        {"jobName":"cadastre-import","jobRunId":"r","success":true,
         "startedAt":"2026-09-26T10:00:00.000Z",
         "completedAt":"2026-09-26T10:00:04.000Z","durationMs":1,
         "itemsScanned":0,"itemsActioned":0,"itemsSkipped":0}
        """
        let withoutKey = try await APIClient.shared.decode(
            Data(json.utf8), as: JobRunEnvelope.self)
        XCTAssertNil(withoutKey.spatial)
    }

    /// `parcelCount` is READ, not recomputed from `matched + created`.
    ///
    /// The server owns that definition. A client that recomputes it is a
    /// second description of one thing, and this repo has spent a week
    /// removing those — so a payload where they disagree must still report
    /// the server's number rather than quietly correcting it.
    func testParcelCountIsTheServersNumberEvenWhenItDisagrees() async throws {
        let e = try await envelope(details: """
        {"tenantId":"t","locationId":"l","fileRecordId":"f","format":"geojson",
         "parcelCount":99,"matched":11,"created":3,"flagged":2,"jobRunId":"r"}
        """)
        XCTAssertEqual(e.spatial?.parcelCount, 99)
        XCTAssertEqual((e.spatial?.matched ?? 0) + (e.spatial?.created ?? 0), 14)
    }

    /// `result` is in the spec's `required` list and is still optional here,
    /// because `JobRunEnvelope` is `["object","null"]` in its own schema — the
    /// `FieldBriefing` lesson. A poll while the job is queued carries null.
    func testAQueuedJobCarriesANullResult() async throws {
        let status = try await APIClient.shared.decode(
            Data(#"{"jobId":"j","state":"waiting","failedReason":null,"result":null}"#.utf8),
            as: ImportJobStatus.self)
        XCTAssertNil(status.result)
        XCTAssertEqual(status.stage, .waiting)
    }
}
