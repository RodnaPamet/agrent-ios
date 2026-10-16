import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Changing the account's picture from the phone (#333, agri-saas #1903).
///
/// ── What the server takes (owner, 2026-10-16) ──
///
/// `POST /api/account/avatar`, one multipart part named `file`: a JPEG or a
/// WebP, at most 4 MB, checked on the magic number. The server applies the
/// EXIF orientation, drops every metadata block, squares to 256×256 and
/// stores WebP. HEIC is refused on purpose: the owner chose to keep HEIF
/// containers away from the server's decoder. iOS can't encode WebP, so the
/// phone sends JPEG.
///
/// ── What the phone sends ──
///
/// The picture already in its final shape: oriented, cover-cropped to the
/// centre and drawn at 256×256, then encoded as JPEG from the pixels alone.
/// So the upload is tens of kilobytes rather than a 3 MB camera file, and no
/// EXIF block (camera, time, GPS) leaves the phone, rather than relying on
/// the server to strip it. The crop is the server's own (`fit: cover`,
/// centred), and the web canvas's, so the picture looks the same whichever
/// client set it.
///
/// Nothing is written to disk: the picked photo's bytes and the JPEG live in
/// memory for the length of the upload.
enum AccountPicture {
    static let path = "/api/account/avatar"

    /// The server's `AVATAR_PX`, and the web canvas's.
    static let side = 256

    /// The web canvas's WebP quality, used here for the JPEG.
    static let quality = 0.85

    static let fileName = "avatar.jpg"
    static let mimeType = "image/jpeg"

    /// Refused before decoding, as `AccountAvatarAPI.maxSourcePixels` is for
    /// a downloaded picture, but higher: this is the farmer's own photo, and
    /// a 48-megapixel camera frame has to pass. The decode below downsamples,
    /// so this bounds what a file may CLAIM, not what is allocated.
    static let maxSourcePixels = 120_000_000

    enum Failure: Error, Equatable {
        /// The library didn't hand the photo over (an iCloud copy offline).
        case notLoaded
        /// The bytes aren't a picture ImageIO can read.
        case unreadable
    }

    // MARK: - The picture

    /// A picked photo, in whatever format the library holds it (HEIC, JPEG,
    /// PNG…), as the JPEG the server takes.
    ///
    /// `nonisolated async`: under this target's nonisolated default it runs
    /// off the main actor, so a full camera frame decodes without stalling
    /// the screen.
    static func jpeg(from data: Data) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(
                  data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maxSourcePixels
        else { throw Failure.unreadable }

        // Decoded at the size the square needs: the SHORT side lands at
        // `side` or more, so the crop below never enlarges. Capped for a
        // panorama, whose short side then falls under `side` and is scaled
        // up a little rather than decoded at full width.
        let long = Double(max(width, height)), short = Double(min(width, height))
        let longSide = min((Double(side) * long / short).rounded(.up), Double(side * 16))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // The orientation BEFORE the crop. A portrait photo is stored
            // sideways with an orientation tag, and cropping the stored frame
            // would centre on the wrong axis.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longSide),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              decoded.width > 0, decoded.height > 0
        else { throw Failure.unreadable }

        return try encode(square(decoded))
    }

    /// Cover-cropped to the centre, at `side`×`side`. White under the photo:
    /// JPEG has no transparency, and a transparent PNG would otherwise turn
    /// black.
    static func square(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.unreadable }
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(frame)
        context.interpolationQuality = .high
        let scale = max(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2,
                                       width: width, height: height))
        guard let squared = context.makeImage() else { throw Failure.unreadable }
        return squared
    }

    /// JPEG from the pixels alone. No properties are handed to the
    /// destination but the quality, so it writes no EXIF, TIFF or GPS
    /// block: there's nothing to strip because nothing was copied.
    static func encode(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                  out, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return out as Data
    }

    // MARK: - The server

    private struct Uploaded: Decodable {
        let imageUrl: String
    }

    /// The new `avatarUrl`. It's root-relative and the same for every
    /// upload (`/api/account/avatar/<userId>`), so its value can't say the
    /// picture changed. `AccountAvatarStore.adopt` is how the card learns.
    static func upload(_ jpeg: Data) async throws -> String {
        let data = try await APIClient.shared.postMultipart(
            path, file: jpeg, fileName: fileName, mimeType: mimeType)
        return try await APIClient.shared.decode(data, as: Uploaded.self).imageUrl
    }

    /// Clears the account's picture, an OAuth provider's photo included, as
    /// on the web. Idempotent on the server.
    static func remove() async throws {
        _ = try await APIClient.shared.deleteReturningData(path)
    }

    // MARK: - Words

    /// The web's labels (`account.profile`), word for word.
    static let uploadTitle = "Качване на снимка"
    static let changeTitle = "Смяна на снимката"
    static let removeTitle = "Премахване"
    static let workingTitle = "Обработка…"

    /// Under the card. The web's note says its browser strips the metadata;
    /// here the phone does, so the sentence is the phone's own.
    static let note = "Снимката се изрязва до квадрат и се смалява на телефона, "
        + "преди да бъде изпратена. Местоположението и другите данни от снимката не се изпращат."

    static let changed = "Снимката е сменена."
    static let removed = "Снимката е премахната."

    /// The server's refusals reach the farmer in its own Bulgarian
    /// (`AVATAR_*`, `UPLOAD_*`; agri-saas #1924, #1928, #1951), so only the
    /// two failures that happen on the phone are worded here.
    static func message(for error: Error) -> String {
        switch error {
        case Failure.notLoaded:
            "Снимката не може да бъде заредена. Ако е в iCloud, проверете връзката и опитайте отново."
        case Failure.unreadable:
            "Тази снимка не може да бъде прочетена. Изберете друга."
        default:
            UserMessage.text(for: error)
        }
    }
}
