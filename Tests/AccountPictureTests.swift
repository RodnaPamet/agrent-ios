import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Agrent

/// The account picture as the phone sends it (#333, agri-saas #1951): a
/// 256×256 JPEG, oriented, centre-cropped, white under transparency and
/// carrying no metadata. Every input is drawn here; no photo is read from
/// anywhere, and nothing is uploaded.
final class AccountPictureTests: XCTestCase {

    // MARK: - The shape

    /// A landscape photo keeps its middle. The thirds are green, red and
    /// blue, so the centre square is red from edge to edge only if the crop
    /// is centred and covers.
    func testALandscapePhotoBecomesACentredSquareJPEG() async throws {
        let wide = try Self.image(width: 600, height: 300) { context in
            Self.fill(context, CGRect(x: 0, y: 0, width: 150, height: 300), Self.green)
            Self.fill(context, CGRect(x: 150, y: 0, width: 300, height: 300), Self.red)
            Self.fill(context, CGRect(x: 450, y: 0, width: 150, height: 300), Self.blue)
        }
        let jpeg = try await AccountPicture.jpeg(from: try Self.encode(wide, as: .png))

        XCTAssertEqual(Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")
        let out = try Self.decode(jpeg)
        XCTAssertEqual(out.width, AccountPicture.side)
        XCTAssertEqual(out.height, AccountPicture.side)
        let pixels = try Self.pixels(out)
        for (x, y) in [(4, 4), (251, 4), (4, 251), (251, 251), (128, 128)] {
            XCTAssertTrue(Self.isRed(pixels.at(x, y)), "(\(x), \(y)) is \(pixels.at(x, y)), not red")
        }
    }

    /// The orientation tag is applied BEFORE the crop. Stored, the frame is
    /// red on the left and blue on the right; tagged 6 (rotate 90° clockwise
    /// to display) it's red on top and blue below. Cropped unrotated, the
    /// top-centre pixel would sit on the red/blue seam.
    func testTheOrientationIsAppliedBeforeTheCrop() async throws {
        let stored = try Self.image(width: 400, height: 200) { context in
            Self.fill(context, CGRect(x: 0, y: 0, width: 200, height: 200), Self.red)
            Self.fill(context, CGRect(x: 200, y: 0, width: 200, height: 200), Self.blue)
        }
        let tagged = try Self.encode(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
        let tag = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
        XCTAssertEqual(tag, 6, "positive control: the input carries the tag")

        let pixels = try Self.pixels(Self.decode(try await AccountPicture.jpeg(from: tagged)))
        XCTAssertTrue(Self.isRed(pixels.at(128, 30)), "top is \(pixels.at(128, 30)), not red")
        XCTAssertTrue(Self.isBlue(pixels.at(128, 226)), "bottom is \(pixels.at(128, 226)), not blue")
    }

    /// JPEG has no transparency. A transparent PNG becomes white, not the
    /// black an unfilled context would give.
    func testTransparencyBecomesWhite() async throws {
        let clear = try Self.image(width: 300, height: 300) { _ in }
        let pixels = try Self.pixels(Self.decode(
            try await AccountPicture.jpeg(from: try Self.encode(clear, as: .png))))
        let middle = pixels.at(128, 128)
        XCTAssertTrue(middle.r > 240 && middle.g > 240 && middle.b > 240, "\(middle) is not white")
    }

    // MARK: - What leaves the phone

    /// No GPS, no camera. The input carries both (synthetic values), and
    /// the JPEG the server receives carries neither.
    func testNoMetadataLeavesThePhone() async throws {
        let photo = try Self.image(width: 320, height: 240) { context in
            Self.fill(context, CGRect(x: 0, y: 0, width: 320, height: 240), Self.green)
        }
        let input = try Self.encode(photo, as: .jpeg, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.0, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 00:00:00"],
        ])
        let before = try Self.properties(input)
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "positive control: the input has GPS")
        XCTAssertNotNil((before[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake],
                        "positive control: the input names a camera")
        XCTAssertNotNil((before[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal],
                        "positive control: the input says when it was taken")

        let after = try Self.properties(try await AccountPicture.jpeg(from: input))
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "GPS survived")
        XCTAssertNil((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake],
                     "the camera survived")
        XCTAssertNil((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal],
                     "the time it was taken survived")
    }

    /// A worst case for JPEG: noise. Still a small fraction of the server's
    /// 4 MB, which is what makes sending it over a field's signal cheap.
    func testTheUploadIsSmall() async throws {
        var seed: UInt32 = 12345
        let noise = try Self.image(width: 1200, height: 900) { context in
            for y in stride(from: 0, to: 900, by: 4) {
                for x in stride(from: 0, to: 1200, by: 4) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let shade = CGFloat(seed >> 24) / 255
                    Self.fill(context, CGRect(x: x, y: y, width: 4, height: 4),
                              CGColor(srgbRed: shade, green: 1 - shade, blue: shade / 2, alpha: 1))
                }
            }
        }
        let jpeg = try await AccountPicture.jpeg(from: try Self.encode(noise, as: .png))
        XCTAssertLessThan(jpeg.count, 150_000)
    }

    /// iPhone photos are HEIC by default, and the server refuses HEIC (owner,
    /// 2026-10-16). Converted on the phone. Skipped where this runtime
    /// can't write HEIC to make the input.
    func testAHEICPhotoIsSentAsJPEG() async throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard writable.contains(UTType.heic.identifier) else {
            throw XCTSkip("this runtime can't encode HEIC to make the input")
        }
        let photo = try Self.image(width: 400, height: 300) { context in
            Self.fill(context, CGRect(x: 0, y: 0, width: 400, height: 300), Self.blue)
        }
        let heic: Data
        do { heic = try Self.encode(photo, as: .heic) } catch {
            throw XCTSkip("HEIC encoding failed on this runtime")
        }
        let jpeg = try await AccountPicture.jpeg(from: heic)
        XCTAssertEqual(Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertTrue(Self.isBlue(try Self.pixels(Self.decode(jpeg)).at(128, 128)))
    }

    func testBytesThatAreNotAPictureAreRefused() async {
        do {
            _ = try await AccountPicture.jpeg(from: Data("not a picture".utf8))
            XCTFail("text became a picture")
        } catch {
            XCTAssertEqual(error as? AccountPicture.Failure, .unreadable)
        }
    }

    /// The one part, as the route reads it: named `file`, a JPEG.
    func testTheUploadIsOnePartNamedFile() {
        let body = APIClient.multipartBody(
            boundary: "B", file: Data([0xFF, 0xD8, 0xFF]), fileName: AccountPicture.fileName,
            mimeType: AccountPicture.mimeType, fields: [:])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertEqual(AccountPicture.path, "/api/account/avatar")
    }

    // MARK: - Words

    func testThePhonesOwnFailuresAreBulgarianSentences() {
        for failure in [AccountPicture.Failure.notLoaded, .unreadable] {
            let text = AccountPicture.message(for: failure)
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertTrue(text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, text)
        }
    }

    /// The server's own Bulgarian for its refusals reaches the screen: no
    /// entry of the phone's shadows it. The sentence here is agri-saas
    /// #1951's `AVATAR_FORMAT_NOT_ALLOWED`.
    func testTheServersRefusalIsSaidInItsWords() {
        let sentence = "Профилната снимка трябва да е във формат JPEG или WebP."
        let error = APIClient.APIError.http(status: 400, code: "AVATAR_FORMAT_NOT_ALLOWED", message: sentence)
        XCTAssertEqual(AccountPicture.message(for: error), sentence)
        XCTAssertNil(UserMessage.bulgarian["AVATAR_NOT_WEBP"], "a retired code needs no sentence")
    }

    // MARK: - Helpers

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "rgb(\(r), \(g), \(b))" }
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        /// `y` from the TOP: a bitmap context's memory starts at the top row.
        func at(_ x: Int, _ y: Int) -> RGB {
            let i = (y * width + x) * 4
            return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
        }
    }

    private static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private static let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    private static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    private static func isRed(_ p: RGB) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
    private static func isBlue(_ p: RGB) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private static func encode(_ image: CGImage, as type: UTType,
                               properties: [CFString: Any] = [:]) throws -> Data {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("could not encode \(type.identifier)")
        }
        return out as Data
    }

    private static func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private static func pixels(_ image: CGImage) throws -> Pixels {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "no context to read pixels from")
        return Pixels(width: image.width, bytes: bytes)
    }
}
