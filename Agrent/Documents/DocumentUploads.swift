import Foundation
import UIKit
import UniformTypeIdentifiers

/// The three ways a file becomes a `DocumentUpload`, kept out of the view so
/// the names and limits can be tested.
enum DocumentUploads {
    /// The phone's own ceiling on one file, before a byte is read into
    /// memory. The server decides what it accepts (and the farm's 2 GB); this
    /// only keeps a 2 GB video from being loaded whole on a phone.
    static let maxBytes = 100_000_000

    /// A scan, already one PDF (`ScanPDF`), named for the day it was made:
    /// «Сканиран документ 30 октомври».
    static func scan(_ pdf: Data, now: Date = Date()) -> DocumentUpload {
        DocumentUpload(data: pdf, fileName: "scan.pdf", mimeType: "application/pdf",
                       suggestedName: "Сканиран документ \(BgDate.dayMonth(now))")
    }

    /// A photo, from the camera or Photos, as a JPEG: the server's pipeline
    /// takes JPEG, and a HEIC from the camera is not something to send it
    /// to find out (the account picture's lesson, #344).
    static func photo(_ image: UIImage, now: Date = Date()) -> DocumentUpload? {
        guard let jpeg = ScanPDF.compressed(image).jpegData(compressionQuality: ScanPDF.quality) else { return nil }
        return DocumentUpload(data: jpeg, fileName: "photo.jpg", mimeType: "image/jpeg",
                              suggestedName: "Снимка \(BgDate.dayMonth(now))")
    }

    enum Refusal: Error, Equatable {
        case tooLarge
        case unreadable

        var message: String {
            switch self {
            case .tooLarge: "Файлът е твърде голям. Изберете файл до 100 МБ."
            case .unreadable: "Файлът не може да бъде прочетен."
            }
        }
    }

    /// A file from Files: its own name (without the extension) to start the
    /// name field, its type from the extension. Read inside its security
    /// scope, and refused before it is read when it is too large.
    static func file(at url: URL) -> Result<DocumentUpload, Refusal> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else {
            return .failure(size > maxBytes ? .tooLarge : .unreadable)
        }
        let ext = url.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let name = url.deletingPathExtension().lastPathComponent
        return .success(DocumentUpload(data: data, fileName: asciiName(ext: ext), mimeType: mime,
                                       suggestedName: name))
    }

    /// The multipart file name: ASCII, by type. The document's real name
    /// travels as its own field (`DocumentsAPI.upload`).
    static func asciiName(ext: String) -> String {
        let clean = ext.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return clean.isEmpty ? "document" : "document.\(clean)"
    }
}
