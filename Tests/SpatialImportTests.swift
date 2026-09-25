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

    // MARK: - The bare error body

    /// These routes answer a bare `{ "error": "..." }` on every failure, and
    /// the reason was being thrown away.
    ///
    /// The envelope has parsed a bare string since the auth work, so it lands
    /// in `code` — and `UserMessage.httpText` uses `code` as a LOOKUP KEY,
    /// matching it against tables and otherwise dropping it. Never printing
    /// it. So «file too large» became a sentence derived from the status.
    func testABareErrorSentenceReachesTheOperator() {
        let raw = APIClient.APIError.http(
            status: 400, code: "File exceeds the 5 MB limit", message: nil)
        let text = UserMessage.text(for: SpatialImportAPI.humanised(raw))
        XCTAssertEqual(text, "File exceeds the 5 MB limit")
    }

    /// AND A CODE IS STILL A CODE. `invalid_grant` is one token, and
    /// `isHumanSentence` would have accepted it as language — which is why the
    /// rule here is a SPACE rather than that function, and why it is applied
    /// only on the routes whose spec documents the bare body as prose.
    func testASingleTokenCodeIsNotMistakenForAMessage() {
        let raw = APIClient.APIError.http(status: 401, code: "invalid_grant", message: nil)
        guard case APIClient.APIError.http(_, let code, let message, _) =
                SpatialImportAPI.humanised(raw) else {
            return XCTFail("shape changed")
        }
        XCTAssertEqual(code, "invalid_grant", "still a code")
        XCTAssertNil(message, "and not promoted to prose")
    }

    /// A canonical envelope is left exactly as it was.
    func testACanonicalEnvelopeIsUntouched() {
        let raw = APIClient.APIError.http(
            status: 409, code: "STALE_DATA", message: "Changed on the server")
        guard case APIClient.APIError.http(_, let code, let message, _) =
                SpatialImportAPI.humanised(raw) else {
            return XCTFail("shape changed")
        }
        XCTAssertEqual(code, "STALE_DATA")
        XCTAssertEqual(message, "Changed on the server")
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
