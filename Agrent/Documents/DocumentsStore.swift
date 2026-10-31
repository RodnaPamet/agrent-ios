import Foundation
import Observation

/// «Документи»'s list and settings (#468), read live, never from disk
/// (`DocumentsAPI`), plus what the page writes: an upload, a settings
/// change, an admin's Drive retry.
@MainActor
@Observable
final class DocumentsStore {
    private(set) var page: LoadState<DocumentsPage> = .loading
    private(set) var settings: LoadState<DocumentSettings> = .loading

    /// An upload in flight, by its name, for the row the page shows while it
    /// goes. One at a time: the button waits.
    private(set) var uploading: String?
    /// A settings change in flight: the controls wait.
    private(set) var saving = false
    /// A write's refusal, said once and dismissed.
    var message: String?

    struct Reads: Sendable {
        var list: @Sendable () async throws -> DocumentsPage = { try await DocumentsAPI.list() }
        var settings: @Sendable () async throws -> DocumentSettings = { try await DocumentsAPI.settings() }
    }

    private let reads: Reads

    init(reads: Reads = Reads()) {
        self.reads = reads
    }

    /// Both reads, side by side. A failure keeps what is on screen and says
    /// so; with nothing on screen it is the page's error state.
    func load() async {
        async let list = Self.result(reads.list)
        async let options = Self.result(reads.settings)
        apply(await list, to: \.page)
        apply(await options, to: \.settings)
    }

    private nonisolated static func result<T: Sendable>(_ read: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    private func apply<T: Equatable & Sendable>(_ result: Result<T, Error>,
                                               to state: ReferenceWritableKeyPath<DocumentsStore, LoadState<T>>) {
        switch result {
        case .success(let value):
            self[keyPath: state] = .loaded(value, .fresh)
        case .failure(let error):
            if self[keyPath: state].value == nil {
                self[keyPath: state] = .failed(UserMessage.text(for: error))
            } else {
                message = UserMessage.text(for: error)
            }
        }
    }

    // MARK: - Upload

    /// The key for the bytes being uploaded, kept while they are the same,
    /// so a retry after a lost answer is the same request (#2495 dedupes on
    /// it) and a different file is a different one.
    @ObservationIgnored private var uploadKey: (file: Data, key: String)?

    /// Up, then the list read again. True when it landed.
    func upload(_ file: DocumentUpload, as name: String,
                send: @escaping @MainActor (DocumentUpload, String, String) async throws -> Void = DocumentsStore.send) async -> Bool {
        guard uploading == nil else { return false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = clean.isEmpty ? file.suggestedName : clean
        uploading = named
        defer { uploading = nil }
        let key = uploadKey.flatMap { $0.file == file.data ? $0.key : nil } ?? UUID().uuidString
        uploadKey = (file.data, key)
        do {
            try await send(file, named, key)
        } catch {
            // `DOCUMENT_STORAGE_FULL` and the scan refusals have their own
            // sentences in `UserMessage`.
            message = UserMessage.text(for: error)
            return false
        }
        uploadKey = nil
        await load()
        return true
    }

    static func send(_ file: DocumentUpload, _ name: String, _ key: String) async throws {
        _ = try await DocumentsAPI.upload(file.data, name: name, fileName: file.fileName,
                                          mimeType: file.mimeType, idempotencyKey: key)
    }

    // MARK: - Settings

    /// An admin's change. The page shows the answer the server gives back.
    func update(retention: DocumentRetention? = nil, driveSync: Bool? = nil) async {
        guard let current = settings.value, current.mayEdit, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let answer = try await DocumentsAPI.update(
                retention: retention ?? current.retention, driveSync: driveSync ?? current.driveSync)
            settings = .loaded(answer, .fresh)
        } catch {
            message = UserMessage.text(for: error)
        }
    }

    /// «Опитай пак» on a FAILED Drive copy: the copy is QUEUED, not made
    /// (agri-saas #2573) — the server answers PENDING at once and a sweep
    /// copies within two minutes — so the list reads again and shows PENDING,
    /// and `awaitsDriveCopy` keeps reading until it settles. A refusal
    /// (`DOCUMENT_DRIVE_SYNC_OFF`, `…_COPY_IN_PROGRESS`, `…_ALREADY_COPIED`)
    /// means the row on screen was out of date: it is said, and the list
    /// read again either way.
    func retryDriveCopy(_ document: FarmDocument) async {
        do {
            try await DocumentsAPI.retryDriveCopy(document.id)
        } catch {
            message = UserMessage.text(for: error)
        }
        await load()
    }

    // MARK: - A copy on its way

    /// A Drive copy is queued on a document still on Agrent: an upload on a
    /// farm with the copy on lands PENDING, and so does a retry. The sweep
    /// runs every two minutes, so the page reads again until it says COPIED
    /// or FAILED (`DocumentsView`).
    var awaitsDriveCopy: Bool {
        page.value?.items.contains { $0.driveState == .pending && !$0.isPurged } ?? false
    }

    /// The read while a copy is on its way: the list only, and a failure
    /// keeps the page as it is and says nothing — nobody asked for it.
    func refreshQuietly() async {
        if let list = try? await reads.list() { page = .loaded(list, .fresh) }
    }
}

/// A file on its way up: from Files, Photos, the camera or the scanner.
struct DocumentUpload: Equatable, Sendable, Identifiable {
    let id = UUID()
    let data: Data
    /// The name the file is sent under. Plain ASCII on purpose; the
    /// document's real name travels as its own field (`DocumentsAPI.upload`).
    let fileName: String
    let mimeType: String
    /// What the name field starts with: the file's own name, or for a scan
    /// «Сканиран документ 30 октомври».
    let suggestedName: String

    var kind: DocumentKind { DocumentKind(contentType: mimeType) }
}
