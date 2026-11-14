import Foundation

/// The person's live updates, over `/api/me/stream` (agri-saas P7.6, #605).
///
/// One connection while the app is active and signed in, closed in the
/// background. A frame says only that something changed — never what — so
/// each one makes the matching store read again over REST. The polls stay as
/// they were: this makes a change show sooner, it is never the only way it
/// shows.
///
/// ── Frames ──
///
/// `data: {"kind", "id", "tenantId"}`, `kind` a field, not an event name:
///   · `notification` — a row in «Известия»; `tenantId` is its farm.
///   · `channel` — a mention or reply; `id` is the CHANNEL.
///   · `dm` — a personal message; `id` is the conversation.
///   · `listing` — Борса changed; `id` and `tenantId` are the sentinel
///     `"listings"`, never a listing or a farm.
/// For `channel` and `dm`, `tenantId` is the sentinel `"person"`: they belong
/// to no farm, so they must NEVER be filtered by membership — doing so drops
/// every one. Unknown kinds are ignored.
///
/// ── Reconnecting ──
///
/// A dropped stream reconnects after a growing pause (5 s doubling to five
/// minutes); a clean frame resets it. A 204 is the server saying not to — the
/// feature is off, or the person is at their three streams — so this waits
/// for the next return to the app instead.
@MainActor
final class LiveUpdates {
    static let shared = LiveUpdates()

    nonisolated static let path = "/api/me/stream"

    /// Posted on the main actor for each frame; `object` is the frame.
    nonisolated static let frameNotification = Notification.Name("bg.agrent.app.liveFrame")

    struct Frame: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable { case notification, channel, dm, listing, unknown }
        let kind: Kind
        let id: String?
        let tenantId: String?

        private enum CodingKeys: String, CodingKey { case kind, id, tenantId }
        init(kind: Kind, id: String?, tenantId: String?) {
            self.kind = kind
            self.id = id
            self.tenantId = tenantId
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .unknown
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            tenantId = try? c.decodeIfPresent(String.self, forKey: .tenantId)
        }
    }

    nonisolated static func frame(_ payload: Data) -> Frame? {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: payload), frame.kind != .unknown else { return nil }
        return frame
    }

    /// The pause before the `attempt`-th reconnect: 5 s doubling, capped.
    nonisolated static func backoff(_ attempt: Int) -> Duration {
        .seconds(min(5 * (1 << min(attempt, 6)), 300))
    }

    private var running: Task<Void, Never>?
    /// Which `run` is current, so one that ends after a stop-and-start does
    /// not forget the newer one.
    private var generation = 0

    func start() {
        guard running == nil else { return }
        #if DEBUG
        // Fixtures answer requests, not a stream: nothing to connect to.
        if UITestSeam.isActive { return }
        #endif
        generation += 1
        let mine = generation
        running = Task { [weak self] in await self?.run(mine) }
    }

    func stop() {
        running?.cancel()
        running = nil
    }

    /// Part of `SessionReset`: the next account opens its own stream.
    func reset() { stop() }

    private func run(_ mine: Int) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let stream = try await APIClient.shared.eventStream(Self.path)
                for try await payload in stream {
                    attempt = 0
                    if let frame = Self.frame(payload) { await deliver(frame) }
                }
            } catch APIClient.APIError.http(let status, _, _, _, _) where status == 204 {
                // Switched off, or three streams already: do not reconnect.
                break
            } catch APIClient.APIError.notSignedIn {
                break
            } catch {
                if Task.isCancelled { break }
            }
            do { try await Task.sleep(for: Self.backoff(attempt)) } catch { break }
            attempt += 1
        }
        if generation == mine { running = nil }
    }

    /// The stores this app keeps app-wide read again; an open screen hears
    /// the frame and reads its own.
    private func deliver(_ frame: Frame) async {
        NotificationCenter.default.post(name: Self.frameNotification, object: frame)
        switch frame.kind {
        case .notification: await NotificationsStore.shared.refresh()
        case .channel: await ChannelUnreadStore.shared.refresh()
        case .dm: await ExchangeUnreadStore.shared.refreshDirect()
        case .listing, .unknown: break
        }
    }
}
