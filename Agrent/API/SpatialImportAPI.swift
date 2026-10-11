import Foundation

/// Parcel-boundary import: one upload, then a poll.
///
/// Every refusal on these two routes is CODED since agri-saas #1633, and
/// `UserMessage` says each in Bulgarian from its `params`.
///
/// They used to answer a bare `{ "error": "<English sentence>" }`, and
/// `humanised` moved that sentence into `message` so the farmer read the
/// server's reason — in English, on a Bulgarian screen (agrent-ios#271).
/// With the codes it is gone: a bare string is a CODE again, used only as
/// a lookup key and never printed, as on every other route.
///
/// A failed JOB is a different path: the poll answers 200 and the reason
/// travels in `ImportJobStatus.failedReason`, which is still English.
enum SpatialImportAPI {
    private static var base: String { "\(FarmPath.root)/locations" }

    static func uploadPath(locationID: String) -> String {
        "\(base)/\(URLEscape.segment(locationID))/spatial-import"
    }

    static func jobPath(locationID: String, jobID: String) -> String {
        "\(uploadPath(locationID: locationID))/\(URLEscape.segment(jobID))"
    }

    /// Stage the file and queue the parse.
    ///
    /// `cropType` is omitted when blank rather than sent empty: the server
    /// reads a blank as "mixed / set later", and an absent field says the same
    /// thing without asking it to interpret an empty string.
    static func upload(
        locationID: String,
        file: Data,
        fileName: String,
        format: SpatialImportFormat,
        cropType: String?
    ) async throws -> SpatialImportAccepted {
        var fields: [String: String] = [:]
        if let cropType = cropType?.recorded { fields["cropType"] = cropType }

        let data = try await APIClient.shared.postMultipart(
            uploadPath(locationID: locationID),
            file: file,
            fileName: fileName,
            mimeType: format.mimeType,
            fields: fields
        )
        return try await APIClient.shared.decode(data, as: SpatialImportAccepted.self)
    }

    static func job(locationID: String, jobID: String) async throws -> ImportJobStatus {
        try await APIClient.shared.get(
            jobPath(locationID: locationID, jobID: jobID), as: ImportJobStatus.self)
    }
}
