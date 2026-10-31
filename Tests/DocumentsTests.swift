import XCTest
@testable import Agrent

/// «Документи» (#468): the agreed rows and settings, what a row says in each
/// state, the warning before an upload, delete and its window, the upload's
/// key, the scanner's PDF, and the Google callback.
final class DocumentsTests: XCTestCase {

    private nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: DocumentsTests.self).url(forResource: name, withExtension: "json")))
    }

    private nonisolated static func day(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private nonisolated static let now = day("2026-10-30T12:00:00Z")

    private nonisolated static func documents() async throws -> [FarmDocument] {
        try await DocumentsAPI.decodeList(from: fixture("documents-list")).items
    }

    // MARK: - Paths

    func testThePathsTakeIdsInThePathAndNoQuery() {
        XCTAssertTrue(DocumentsAPI.listPath.hasSuffix("/documents"))
        XCTAssertTrue(DocumentsAPI.contentPath("d 1").hasSuffix("/documents/d%201/content"))
        XCTAssertTrue(DocumentsAPI.driveCopyPath("d").hasSuffix("/documents/d/drive-copy"))
        for path in [DocumentsAPI.listPath, DocumentsAPI.settingsPath, DocumentsAPI.documentPath("d")] {
            XCTAssertFalse(path.contains("?"), path)
            XCTAssertTrue(path.hasPrefix(FarmPath.root), path)
        }
    }

    // MARK: - Decoding

    /// Every state the agreed rows can be in decodes. A deleted row has no
    /// name, and a row with no id is dropped, not the list.
    func testTheAgreedRowsDecode() async throws {
        let rows = try await Self.documents()
        XCTAssertEqual(rows.map(\.id), ["doc_fixture_scan", "doc_fixture_photo", "doc_fixture_expired", "doc_fixture_deleted"])
        XCTAssertNil(rows[3].name)
        XCTAssertEqual(rows[3].purgeReason, .deleted)
        XCTAssertEqual(rows[0].expiresOn, "2027-10-29")
        XCTAssertEqual(rows[0].retention, .year1)
        XCTAssertEqual(rows[1].driveState, .failed)

        let odd = #"{"rows":[{"name":"без id"},{"id":"x","sizeBytes":"много","drive":{"state":"NEW"},"purgeReason":"LATER"}],"truncated":true}"#
        let page = try await DocumentsAPI.decodeList(from: Data(odd.utf8))
        XCTAssertEqual(page.items.map(\.id), ["x"], "the row without an id is dropped, the other kept")
        XCTAssertNil(page.items[0].sizeBytes, "an odd field costs the field")
        XCTAssertEqual(page.items[0].driveState, .unknown)
        XCTAssertEqual(page.items[0].purgeReason, .unknown)
        XCTAssertTrue(page.truncated)
    }

    func testTheSettingsDecode() async throws {
        let settings = try await APIClient.shared.decode(try Self.fixture("documents-settings"), as: DocumentSettings.self)
        XCTAssertEqual(settings.retention, .year1)
        XCTAssertTrue(settings.driveSync)
        XCTAssertEqual(settings.google?.connected, true)
        XCTAssertEqual(settings.limitBytes, 2_147_483_648)
        XCTAssertTrue(settings.mayEdit)
        let odd = try await APIClient.shared.decode(Data(#"{"retention":"P9Y"}"#.utf8), as: DocumentSettings.self)
        XCTAssertEqual(odd.retention, .unknown, "an unknown period reads as unknown, not a failure")
        XCTAssertFalse(odd.mayEdit)
    }

    // MARK: - What a row says

    func testEachStateSaysWhereTheDocumentStands() async throws {
        let rows = try await Self.documents()
        let live = DocumentRowText(rows[0], now: Self.now)
        XCTAssertEqual(live.title, "Сертификат за семена")
        XCTAssertEqual(live.status, "Изтича на \(BgDate.rowDay(BgDate.parseISODay("2027-10-29")!, now: Self.now))")
        XCTAssertEqual(live.drive, "Копие в Google Drive")
        XCTAssertEqual(live.details.first, "PDF")
        XCTAssertTrue(live.details.contains("1,2 МБ"), "\(live.details)")

        let kept = DocumentRowText(rows[1], now: Self.now)
        XCTAssertEqual(kept.status, "Пази се без срок")
        XCTAssertTrue(kept.driveFailed)

        XCTAssertEqual(DocumentRowText(rows[2], now: Self.now).status, "Само в Google Drive")

        let deleted = DocumentRowText(rows[3], now: Self.now)
        XCTAssertEqual(deleted.title, "Изтрит документ")
        XCTAssertTrue(deleted.status.hasPrefix("Изтрит на "), deleted.status)
        XCTAssertTrue(deleted.status.hasSuffix("от Иван Фикстуров"), deleted.status)
        XCTAssertNil(deleted.drive, "a gone document has no Drive line")
        XCTAssertFalse(deleted.spoken.contains("·"))
    }

    /// Expired with no Drive copy: the date it went, not «Само в Google Drive».
    func testAnExpiredDocumentWithoutACopySaysWhenItWent() async throws {
        let body = #"{"rows":[{"id":"e","name":"Стар","purgedAt":"2026-10-01T03:00:00.000Z","purgeReason":"EXPIRED","drive":{"state":"OFF"}}],"truncated":false}"#
        let row = try await DocumentsAPI.decodeList(from: Data(body.utf8)).items[0]
        XCTAssertEqual(DocumentRowText(row, now: Self.now).status, "Изтекъл срок на 1 октомври")
    }

    func testSizesReadAsBulgarianWritesThem() {
        XCTAssertEqual(DocumentSize.text(999), "999 Б")
        XCTAssertEqual(DocumentSize.text(348_160), "340 КБ")
        XCTAssertEqual(DocumentSize.text(1_258_291), "1,2 МБ")
        XCTAssertEqual(DocumentSize.text(2_147_483_648), "2 ГБ", "the server's 2 GiB ceiling reads as 2 ГБ")
        XCTAssertEqual(DocumentSize.usage(used: 131_072_000, limit: 2_147_483_648), "Използвани 125 МБ от 2 ГБ")
    }

    // MARK: - The period and the warning

    /// Calendar months, clamped to the month's end: never N×30 days.
    func testThePeriodCountsCalendarMonths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        let august31 = Self.day("2026-08-31T09:00:00Z")
        let feb = DocumentRetention.months6.expiry(from: august31, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: feb), DateComponents(month: 2, day: 28))
        let year = DocumentRetention.year1.expiry(from: Self.day("2026-10-30T09:00:00Z"), calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: year), DateComponents(year: 2027, month: 10, day: 30))
        XCTAssertNil(DocumentRetention.none.expiry(from: august31, calendar: calendar))
    }

    func testTheWarningComesOnlyWhenNothingWouldBeKept() {
        func settings(_ retention: DocumentRetention, sync: Bool, connected: Bool) -> DocumentSettings {
            DocumentSettings(retention: retention, driveSync: sync,
                             google: .init(connected: connected, accountEmail: nil),
                             usedBytes: 0, limitBytes: 1, mayEdit: true)
        }
        XCTAssertNotNil(UploadWarning.text(settings(.year1, sync: false, connected: true), now: Self.now))
        XCTAssertNotNil(UploadWarning.text(settings(.year1, sync: true, connected: false), now: Self.now),
                        "sync on but Google not connected keeps no copy either")
        XCTAssertNil(UploadWarning.text(settings(.year1, sync: true, connected: true), now: Self.now))
        XCTAssertNil(UploadWarning.text(settings(.none, sync: false, connected: false), now: Self.now))
        // Foundation puts a no-break space before «г.»; every kind of space
        // is compared as a plain one.
        let text = UploadWarning.text(settings(.months3, sync: false, connected: false), now: Self.now)!
            .components(separatedBy: .whitespaces).joined(separator: " ")
        XCTAssertTrue(text.hasPrefix("Документът ще бъде изтрит от Agrent на 30 януари 2027 г."), text)
    }

    // MARK: - Delete

    func testDeleteIsOfferedWhereItWouldSucceed() async throws {
        let rows = try await Self.documents()
        let writer = CurrentUser(id: "u", name: nil, email: nil, role: nil,
                                 permissions: CurrentUser.Permissions(canWrite: true, canAdmin: false))
        let reader = CurrentUser(id: "u", name: nil, email: nil, role: nil,
                                 permissions: CurrentUser.Permissions(canWrite: false, canAdmin: false))
        XCTAssertTrue(DocumentRemoval.offered(rows[0], to: writer))
        XCTAssertFalse(DocumentRemoval.offered(rows[0], to: reader), "a reader")
        XCTAssertFalse(DocumentRemoval.offered(rows[3], to: writer), "a tombstone")
        XCTAssertFalse(DocumentRemoval.offered(rows[0], to: nil))
    }

    @MainActor
    func testTheWindowThenTheSendAndAFailureSaid() async throws {
        let rows = try await Self.documents()
        @MainActor final class Sent { var ids: [String] = []; var refuse = false }
        let sent = Sent()
        let removal = DocumentRemoval(window: .seconds(600)) { id in
            sent.ids.append(id)
            if sent.refuse { throw APIClient.APIError.http(status: 403, code: "FORBIDDEN", message: nil) }
        }
        removal.remove(rows[0])
        XCTAssertEqual(removal.visible(rows).map(\.id), ["doc_fixture_photo", "doc_fixture_expired", "doc_fixture_deleted"])
        removal.undo()
        XCTAssertEqual(removal.visible(rows).count, 4, "«Отмени» brings it back")
        XCTAssertEqual(sent.ids, [], "nothing sent inside the window")

        removal.remove(rows[0])
        await removal.commit(rows[0].id)
        XCTAssertEqual(sent.ids, ["doc_fixture_scan"])
        XCTAssertEqual(removal.deletions, 1)

        sent.refuse = true
        removal.remove(rows[1])
        await removal.commit(rows[1].id)
        XCTAssertTrue(removal.showsFailure)
        XCTAssertNotNil(removal.failure)
        XCTAssertTrue(removal.visible(rows).contains { $0.id == rows[1].id }, "a refused delete comes back")
    }

    // MARK: - Upload

    /// A retry of the same bytes is the same request; another file is another.
    @MainActor
    func testARetryKeepsItsKey() async {
        @MainActor final class Sends { var keys: [String] = []; var fail = true }
        let sends = Sends()
        let store = DocumentsStore(reads: .init(
            list: { DocumentsPage(items: [], truncated: false) },
            settings: { throw URLError(.notConnectedToInternet) }))
        let file = DocumentUploads.scan(Data("pdf".utf8), now: Self.now)
        let send: @MainActor (DocumentUpload, String, String) async throws -> Void = { _, _, key in
            sends.keys.append(key)
            if sends.fail { throw URLError(.networkConnectionLost) }
        }
        let first = await store.upload(file, as: "Договор", send: send)
        XCTAssertFalse(first)
        sends.fail = false
        let second = await store.upload(file, as: "Договор", send: send)
        XCTAssertTrue(second)
        XCTAssertEqual(sends.keys.count, 2)
        XCTAssertEqual(sends.keys[0], sends.keys[1], "the same bytes, the same key")
        _ = await store.upload(DocumentUploads.scan(Data("other".utf8), now: Self.now), as: "Друг", send: send)
        XCTAssertNotEqual(sends.keys[2], sends.keys[1], "another file, another key")
    }

    /// A copy on its way (agri-saas #2573): queued, not made, so the page
    /// reads again while a row is PENDING, quietly — a failed read keeps the
    /// page and says nothing — and stops once none is.
    @MainActor
    func testAQueuedCopyIsReadUntilItSettles() async throws {
        func page(_ state: String) async throws -> DocumentsPage {
            try await DocumentsAPI.decodeList(from: Data(#"""
            {"rows":[{"id":"doc_synthetic","name":"Договор","contentType":"application/pdf","sizeBytes":10,
              "uploadedAt":"2026-10-31T10:00:00.000Z","uploadedBy":{"id":"u1","name":null},"expiresOn":null,
              "retention":"P1Y","purgedAt":null,"purgeReason":null,"purgedBy":null,"mayDelete":true,
              "drive":{"state":"\#(state)"}}],"truncated":false}
            """#.utf8))
        }
        @MainActor final class Answers { var next: Result<DocumentsPage, Error> = .failure(URLError(.timedOut)) }
        let answers = Answers()
        let pending = try await page("PENDING")
        answers.next = .success(pending)
        let store = DocumentsStore(reads: .init(
            list: { try await MainActor.run { try answers.next.get() } },
            settings: { throw URLError(.notConnectedToInternet) }))
        await store.load()
        XCTAssertTrue(store.awaitsDriveCopy)

        store.message = nil
        answers.next = .failure(URLError(.timedOut))
        await store.refreshQuietly()
        XCTAssertTrue(store.awaitsDriveCopy, "a failed quiet read keeps the page")
        XCTAssertNil(store.message, "and says nothing")

        answers.next = .success(try await page("COPIED"))
        await store.refreshQuietly()
        XCTAssertFalse(store.awaitsDriveCopy, "settled: the reading stops")
    }

    func testAScanIsNamedForItsDay() {
        let scan = DocumentUploads.scan(Data(), now: Self.now)
        XCTAssertEqual(scan.suggestedName, "Сканиран документ 30 октомври")
        XCTAssertEqual(scan.mimeType, "application/pdf")
        XCTAssertEqual(DocumentUploads.asciiName(ext: "PDF"), "document.PDF")
        XCTAssertEqual(DocumentUploads.asciiName(ext: "договор"), "document")
    }

    /// The scanner's pages are ONE PDF, a page each, each scaled down.
    func testTheScanIsOnePDF() throws {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 4000)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        }
        let pdf = ScanPDF.make([page, page])
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertLessThanOrEqual(max(ScanPDF.compressed(page).size.width, ScanPDF.compressed(page).size.height), ScanPDF.maxSide)
    }

    func testAPreviewFileHasAnExtensionAndNoPath() {
        XCTAssertEqual(PreviewFile.safeName(title: "Договор", fileName: "../x/Договор.pdf", contentType: nil), "Договор.pdf")
        XCTAssertEqual(PreviewFile.safeName(title: "Снимка", fileName: nil, contentType: "image/jpeg"), "Снимка.jpg")
        XCTAssertEqual(PreviewFile.safeName(title: "a/b", fileName: nil, contentType: "application/pdf"), "a-b.pdf")
    }

    /// Every refusal the library has is said in Bulgarian, and the two scan
    /// answers differently (backend 1, 2026-10-31).
    func testTheLibrarysRefusalsAreBulgarian() {
        func said(_ code: String, _ status: Int) -> String {
            UserMessage.text(for: APIClient.APIError.http(status: status, code: code, message: "English prose"))
        }
        XCTAssertEqual(said("FILE_SCAN_PENDING", 403), "Файлът още се проверява за вируси. Опитайте след малко.")
        XCTAssertEqual(said("FILE_SCAN_REJECTED", 403), "Файлът е отказан при проверката за вируси.")
        XCTAssertNotEqual(said("FILE_SCAN_PENDING", 403), said("FILE_SCAN_REJECTED", 403))
        XCTAssertEqual(said("DOCUMENT_PURGED", 404), "Файлът вече не е в Agrent.")
        XCTAssertEqual(said("DOCUMENT_NOT_DOWNLOADABLE", 409), "Файлът не беше качен докрай. Качете го отново.")
        XCTAssertEqual(said("DOCUMENT_NOT_FOUND", 404), "Няма такъв документ.")
        XCTAssertEqual(said("DOCUMENT_DELETE_NOT_ALLOWED", 403), "Нямате право да изтриете този документ.")
        XCTAssertTrue(said("DOCUMENT_STORAGE_FULL", 403).hasPrefix("Мястото за документи"), "no numbers: the plain sentence")
        let full = UserMessage.text(for: APIClient.APIError.http(
            status: 403, code: "DOCUMENT_STORAGE_FULL", message: nil,
            params: ["usedBytes": "2040109466", "limitBytes": "2147483648", "incomingBytes": "5242880"]))
        XCTAssertEqual(full, "Мястото за документи е запълнено (1,9 ГБ от 2 ГБ). Изтрийте стари документи, за да освободите място.")
        XCTAssertEqual(said("DOCUMENT_RETENTION_INVALID", 400), "Срокът на съхранение не беше приет. Изберете го отново.")
        // The Drive retry's three refusals, each its own sentence.
        // agri-saas #2573's codes, in its catalogue's words.
        let drive = ["DOCUMENT_DRIVE_SYNC_OFF", "DOCUMENT_DRIVE_COPY_IN_PROGRESS", "DOCUMENT_DRIVE_ALREADY_COPIED"]
            .map { said($0, 409) }
        XCTAssertEqual(Set(drive).count, 3)
        XCTAssertEqual(drive[2], "Документът вече е в Google Drive.")
        XCTAssertTrue(drive[1].hasPrefix("Копието вече е на път"))
    }

    // MARK: - Google

    /// agri-saas #2581: the phone asks for the native branch and nothing
    /// else — the return is a server constant — behind `integrations.google`.
    func testTheConnectAsksForTheNativeBranchOnly() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GoogleDriveConnect.Request()))
        XCTAssertEqual(body as? [String: String], ["client": "ios"])
        XCTAssertEqual(GoogleDriveConnect.flag, "integrations.google")
        XCTAssertTrue(UserMessage.isBulgarianSentence(DriveSwitchText.connectOff))
        XCTAssertTrue(UserMessage.isBulgarianSentence(UserMessage.bulgarian["GOOGLE_NATIVE_RETURN_NOT_ALLOWED"] ?? ""))
    }

    func testTheCallbackSaysHowItWent() {
        XCTAssertEqual(GoogleDriveConnect.outcome(of: URL(string: "bg.agrent.app://integrations/google?result=connected")!), .connected)
        XCTAssertEqual(GoogleDriveConnect.outcome(of: URL(string: "bg.agrent.app://integrations/google?error=access_denied")!),
                       .refused("Отказахте достъпа до Google Drive."))
        // The closed set (agri-saas #2495): each its own sentence, and
        // anything else the set's own fallback.
        let set = ["access_denied", "insufficient_scope", "state_expired", "state_invalid",
                   "token_exchange_failed", "not_admin", "internal_error"]
        let sentences = set.map { GoogleDriveConnect.sentence(for: $0) }
        XCTAssertEqual(Set(sentences).count, set.count, "seven codes, seven sentences")
        XCTAssertEqual(GoogleDriveConnect.sentence(for: "something_new"), GoogleDriveConnect.sentence(for: "internal_error"))
        XCTAssertTrue(sentences.allSatisfy { $0.hasSuffix(".") })
        if case .refused = GoogleDriveConnect.outcome(of: URL(string: "bg.agrent.app://integrations/google")!) {} else {
            XCTFail("a callback with nothing in it is not a connection")
        }
    }

    // MARK: - Where it lives

    func testItIsASurfaceButNotTheOperators() {
        XCTAssertEqual(AppSurface.documents.rawValue, "/documents")
        XCTAssertEqual(AppSurface.documents.label, "Документи")
        XCTAssertFalse(AppSurface.documents.isOperatorAllowed)
        XCTAssertFalse(AppSurface.fallback.contains(.documents), "in the menu by default, not the bar")
    }
}
