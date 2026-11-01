import Foundation

/// Which screens open and which key actions are done, for the superuser's
/// usage page (#493, owner 2026-11-01: "our server, per account").
/// `POST /api/t/{tenantSlug}/usage-events`, agri-saas's frozen contract
/// (backend 1, 2026-11-01).
///
/// ── Nothing a person typed or chose ──
///
/// An event is a NAME from a closed list (`Name`, the server's exact strings)
/// and, for a screen, a static SURFACE (`Surface`): never a record's id, a
/// crop, a parcel, a position or any text. The API takes only those two
/// enums, so there is no way to put anything else in. `parcel_located` says
/// the «you are here» tick was used; the position never leaves the phone
/// (#492). App Store Connect: Product Interaction, Analytics, linked to the
/// user, not tracking.
///
/// ── Never in the way ──
///
/// - Recorded only while the server's `usage.events` flag is on for this
///   person (resolved in `/api/auth/me`), so before that nothing is queued
///   and nothing is sent.
/// - In memory only: no file, no cache. An event lost to a killed app is a
///   count off by one.
/// - Sent in batches: at 20, every two minutes, and when the app goes to the
///   background. Any answer but 2xx drops the batch, with no retry and
///   nothing shown. A 403 or 404 (switched off, or an older server) stops
///   sending for the rest of the session.
///
/// ── Whose and which farm's ──
///
/// Each event keeps the farm it happened in and goes to that farm's path,
/// whichever farm is open when the batch leaves. A sign-out empties the queue
/// (`SessionReset.resetUserState`), so one person's events never travel
/// under the next person's token. The server takes the user and farm from
/// the session, never from the body.
@MainActor
final class UsageEvents {
    static let shared = UsageEvents()

    /// The server's names, exactly: its frozen 24 and the two custody moves
    /// asked for with them (`listing_fulfilled`, `listing_withdrawn`). A name
    /// the server does not know is dropped there, never refused.
    enum Name: String, CaseIterable, Sendable {
        case screenOpened = "screen_opened"
        case treatmentSaved = "treatment_saved"
        case activitySaved = "activity_saved"
        case treatmentCorrected = "treatment_corrected"
        case treatmentDeleted = "treatment_deleted"
        case diaryPDFDownloaded = "diary_pdf_downloaded"
        case farmDiaryDownloaded = "farm_diary_downloaded"
        case costSaved = "cost_saved"
        case costDeleted = "cost_deleted"
        case invoiceScanned = "invoice_scanned"
        case taskCreated = "task_created"
        case taskClosed = "task_closed"
        case taskCommentAdded = "task_comment_added"
        case documentUploaded = "document_uploaded"
        case documentScanned = "document_scanned"
        case driveCopyRequested = "drive_copy_requested"
        case listingCreated = "listing_created"
        case listingEdited = "listing_edited"
        case listingFulfilled = "listing_fulfilled"
        case listingWithdrawn = "listing_withdrawn"
        case inquirySent = "inquiry_sent"
        case messageSent = "message_sent"
        case assistantAsked = "assistant_asked"
        case assistantEntryOpened = "assistant_entry_opened"
        case notificationOpened = "notification_opened"
        case parcelLocated = "parcel_located"
    }

    /// A screen, by its static route: never one with an id in it.
    enum Surface: Equatable, Sendable {
        case app(AppSurface)
        case mechanisatorHome
        case profile

        var wire: String {
            switch self {
            case .app(let surface): surface.rawValue
            case .mechanisatorHome: "mechanisator_home"
            case .profile: "profile"
            }
        }
    }

    struct Event: Encodable, Equatable, Sendable {
        let name: String
        let surface: String?
        let at: Date
    }

    struct Batch: Encodable, Sendable {
        let events: [Event]
    }

    static let flag = "usage.events"

    /// `/api/t/{farm}/usage-events`: the farm the events happened in.
    nonisolated static func path(farm: String) -> String { FarmPath.root(for: farm) + "/usage-events" }
    /// The server's cap per request.
    static let batchLimit = 50
    /// A full batch goes at once rather than waiting for the timer.
    static let sendAt = 20

    /// Waiting to go, by the farm they happened in.
    private(set) var queued: [String: [Event]] = [:]
    /// A 403 or 404 this session: switched off, or a server without it.
    private(set) var refused = false

    private var timer: Task<Void, Never>?

    /// Swapped in tests: the request, which answers with its status.
    var send: @Sendable (_ path: String, _ batch: Batch) async -> Int = { path, batch in
        do {
            _ = try await APIClient.shared.postReturningData(path, body: batch, idempotencyKey: nil)
            return 204
        } catch APIClient.APIError.http(let status, _, _, _, _) {
            return status
        } catch {
            return 0
        }
    }

    /// Whether events are recorded at all: the flag, as `/me` resolved it.
    var isOn: () -> Bool = { FeatureFlags.shared.isOn(UsageEvents.flag) }
    /// The farm an event happened in.
    var farm: () -> String? = { FarmPath.openSlug }

    func screen(_ surface: Surface) {
        add(Event(name: Name.screenOpened.rawValue, surface: surface.wire, at: Date()))
    }

    func record(_ name: Name) {
        precondition(name != .screenOpened, "a screen goes through screen(_:), with its surface")
        add(Event(name: name.rawValue, surface: nil, at: Date()))
    }

    /// From code off the main actor: an API call that just succeeded.
    nonisolated static func note(_ name: Name) {
        Task { @MainActor in shared.record(name) }
    }

    private func add(_ event: Event) {
        guard !refused, isOn(), let farm = farm(), !farm.isEmpty else { return }
        queued[farm, default: []].append(event)
        if queued.values.reduce(0, { $0 + $1.count }) >= Self.sendAt {
            Task { await flush() }
        } else {
            startTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.timer = nil
            await self?.flush()
        }
    }

    /// Everything queued, now: each farm's events to that farm, at most 50 a
    /// request. Whatever the answer, those events are gone from the queue.
    func flush() async {
        timer?.cancel()
        timer = nil
        let taken = queued
        queued = [:]
        for (farm, events) in taken.sorted(by: { $0.key < $1.key }) {
            for start in stride(from: 0, to: events.count, by: Self.batchLimit) {
                guard !refused else { return }
                let batch = Batch(events: Array(events[start..<min(start + Self.batchLimit, events.count)]))
                let status = await send(Self.path(farm: farm), batch)
                if status == 403 || status == 404 { refused = true }
            }
        }
    }

    /// A sign-out: the queue was the last person's.
    func reset() {
        timer?.cancel()
        timer = nil
        queued = [:]
        refused = false
    }
}
