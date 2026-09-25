import Foundation

/// Parcel-boundary import: one upload, then a poll.
enum SpatialImportAPI {
    private static var base: String { "/api/t/\(Config.tenantSlug)/locations" }

    static func uploadPath(locationID: String) -> String {
        "\(base)/\(locationID)/spatial-import"
    }

    static func jobPath(locationID: String, jobID: String) -> String {
        "\(base)/\(locationID)/spatial-import/\(jobID)"
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

        do {
            let data = try await APIClient.shared.postMultipart(
                uploadPath(locationID: locationID),
                file: file,
                fileName: fileName,
                mimeType: format.mimeType,
                fields: fields
            )
            return try await APIClient.shared.decode(data, as: SpatialImportAccepted.self)
        } catch {
            throw humanised(error)
        }
    }

    static func job(locationID: String, jobID: String) async throws -> ImportJobStatus {
        do {
            return try await APIClient.shared.get(
                jobPath(locationID: locationID, jobID: jobID), as: ImportJobStatus.self)
        } catch {
            throw humanised(error)
        }
    }

    /// Move a BARE `{ "error": "..." }` from `code` into `message`.
    ///
    /// ── The failure this fixes is subtle and I got it wrong once ──
    ///
    /// These routes answer the bare form on EVERY failure, which the spec says
    /// outright. I first reported to the server session that this client could
    /// not parse it at all; that was wrong — `ErrorEnvelope.Err` has decoded a
    /// bare string since the auth work, because `/api/auth` answers
    /// `{"error":"invalid_grant"}`.
    ///
    /// What actually breaks is downstream. The bare string lands in `code`,
    /// and `UserMessage.httpText` treats `code` as a LOOKUP KEY — it is matched
    /// against a Bulgarian table and an interpolation table and otherwise
    /// dropped. It is never printed. So the server's real reason («file too
    /// large», «unsupported extension», «could not parse») was discarded and
    /// the farmer got a sentence derived from the status.
    ///
    /// ── Why a space, and not `isHumanSentence` ──
    ///
    /// The obvious fix is to copy the bare string into `message` for
    /// everything, and it regresses the auth path: `isHumanSentence` accepts a
    /// single lowercase word as language, so `invalid_grant` would be shown to
    /// an operator verbatim. A CODE is one token; a MESSAGE is a sentence. The
    /// space is what separates them, it is stricter than `isHumanSentence`, and
    /// it is applied ONLY on these routes — where the spec documents the bare
    /// body as prose — rather than globally.
    static func humanised(_ error: Error) -> Error {
        guard case APIClient.APIError.http(let status, let code, let message, let params) = error,
              message == nil,
              let code,
              code.contains(" ")
        else { return error }
        return APIClient.APIError.http(
            status: status, code: nil, message: code, params: params)
    }
}
