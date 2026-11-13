import AVFoundation
import XCTest
@testable import Agrent

/// Photos and voice notes on channel posts (P9.6, #598) against agri-saas
/// #3045. Nothing here uploads or records; the tone is generated, not a voice.
final class ChannelMediaTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)))
    }

    func testThePaths() {
        XCTAssertEqual(ChannelsAPI.mediaPath("c1"), "/api/social/channels/c1/media")
        XCTAssertEqual(ChannelsAPI.attachmentPath("p1"), "/api/social/channel-posts/p1/attachment")
    }

    /// The field NAME says which kind — the server refuses both at once.
    func testTheFieldNameSaysTheKind() throws {
        let voice = ChannelMedia(kind: .voice(durationMs: 45_000), data: Data([1]))
        XCTAssertEqual(voice.field, "voice")
        XCTAssertEqual(voice.durationMs, 45_000)
        XCTAssertEqual(voice.mimeType, "audio/mp4")
        let photo = ChannelMedia(kind: .photo, data: Data([1]))
        XCTAssertEqual(photo.field, "photo")
        XCTAssertNil(photo.durationMs, "a photo carries no duration")
        XCTAssertEqual(photo.mimeType, "image/jpeg")

        let body = APIClient.multipartBody(boundary: "B", file: Data("x".utf8), fileName: voice.fileName,
                                           mimeType: voice.mimeType, fields: ["durationMs": "45000"],
                                           fileField: voice.field)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("name=\"voice\"; filename=\"glas.m4a\""))
        XCTAssertTrue(text.contains("name=\"durationMs\"\r\n\r\n45000"))
        XCTAssertFalse(text.contains("name=\"file\""), "positive control: the default name is not used")
    }

    @MainActor func testTheRecorderWritesAVoiceBitrate() {
        let settings = VoiceNoteRecorder.settings
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 64_000)
        // 64 kbps for the full two minutes stays under the 1.5 MB ceiling.
        XCTAssertLessThan(64_000 / 8 * 120, ChannelMedia.maxVoiceBytes)
        XCTAssertEqual(VoiceNoteRecorder.limit, 120)
    }

    /// The generated tone is AAC m4a at the recorder's settings: brand
    /// `M4A `, which the server accepts, and no location atom.
    func testARecordingAtTheseSettingsCarriesNoLocation() throws {
        let tone = try fixture("voice-tone", "m4a")
        XCTAssertEqual(String(decoding: tone[8..<12], as: UTF8.self), "M4A ")
        XCTAssertFalse(ChannelMedia.carriesLocation(tone))
    }

    func testALocationAtomIsFoundInTheBoxTreeButNotInTheAudio() {
        func box(_ type: [UInt8], _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + type + payload
        }
        let ftyp = box(Array("ftyp".utf8), Array("M4A ".utf8) + [0, 0, 0, 0])
        let xyz = box([0xA9, 0x78, 0x79, 0x7A], Array("+42.7+023.3/".utf8))
        let withXYZ = ftyp + box(Array("moov".utf8), box(Array("udta".utf8), xyz))
        XCTAssertTrue(ChannelMedia.carriesLocation(Data(withXYZ)))

        let loci = box(Array("loci".utf8), [0, 0, 0, 0])
        let withLoci = ftyp + box(Array("moov".utf8), box(Array("udta".utf8), loci))
        XCTAssertTrue(ChannelMedia.carriesLocation(Data(withLoci)))

        // «loci» spelled by chance inside the audio is not a box.
        let audio = ftyp + box(Array("mdat".utf8), Array("....loci....".utf8))
        XCTAssertFalse(ChannelMedia.carriesLocation(Data(audio)))
        // An encoder tag is not location.
        let tool = box([0xA9, 0x74, 0x6F, 0x6F], Array("Lavf".utf8))
        XCTAssertFalse(ChannelMedia.carriesLocation(Data(ftyp + box(Array("moov".utf8), box(Array("udta".utf8), tool)))))
    }

    func testAnAttachmentPostMayHaveNoText() async throws {
        let data = Data("""
        {"posts":[
          {"id":"p1","authorUserId":"u1","body":"","kind":"POST","createdAt":"2026-11-13T09:00:00.000Z","deleted":false,
           "resolvedAt":null,"replyCount":0,"attachment":{"mime":"audio/mp4","bytes":360000,"durationMs":45000}},
          {"id":"p2","authorUserId":"u1","body":"Нивата днес","kind":"POST","createdAt":"2026-11-13T08:00:00.000Z","deleted":false,
           "resolvedAt":null,"replyCount":0,"attachment":{"mime":"image/jpeg","bytes":200000,"durationMs":null}},
          {"id":"p3","authorUserId":"u1","body":"","kind":"POST","createdAt":"2026-11-13T07:00:00.000Z","deleted":true,
           "resolvedAt":null,"replyCount":0,"attachment":{"mime":"audio/mp4","bytes":1,"durationMs":1000}}
        ],"hasMore":false}
        """.utf8)
        let posts = try await APIClient.shared.decode(data, as: ChannelPage.self).posts
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts[0].body, "")
        XCTAssertFalse(posts[0].deleted, "an empty body with deleted: false is an attachment post")
        XCTAssertEqual(posts[0].attachment?.isVoice, true)
        XCTAssertEqual(ChannelWords.attachment(try XCTUnwrap(posts[0].attachment)), "Гласово съобщение, 0:45")
        XCTAssertEqual(posts[1].attachment?.isVoice, false)
        XCTAssertEqual(ChannelWords.attachment(try XCTUnwrap(posts[1].attachment)), "Снимка")
        XCTAssertNil(posts[2].attachment, "a removed post serves no bytes, so it shows none")
    }

    func testTheClockAndItsSpokenForm() {
        XCTAssertEqual(VoiceNoteWords.clock(ms: 45_000), "0:45")
        XCTAssertEqual(VoiceNoteWords.clock(ms: 120_000), "2:00")
        XCTAssertEqual(VoiceNoteWords.clock(65.9), "1:05")
        XCTAssertEqual(VoiceNoteWords.spoken(ms: 45_000), "45 секунди")
        XCTAssertEqual(VoiceNoteWords.spoken(ms: 61_000), "1 минута и 1 секунда")
        XCTAssertEqual(VoiceNoteWords.spoken(ms: 120_000), "2 минути")
    }
}
