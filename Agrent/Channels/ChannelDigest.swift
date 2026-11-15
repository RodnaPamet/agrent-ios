import Foundation
import Observation

/// The 07:15 channel digest (#620; agri-saas #3076, P9.7): a morning recap
/// of the person's channel mentions and replies, by push, between 07:15 and
/// 08:15 Sofia time. Opt-in, person-scoped, and ADDITIVE: it adds a recap
/// and holds nothing back, so the per-farm `DAILY_DIGEST` batching is a
/// different control and is never drawn as this one.
///
/// The state rides `/api/auth/me` (`channelDigestOptIn`); there is no read
/// of its own. The write is `PUT /api/account/channel-digest {optIn}`, and
/// a body without `optIn` is a 400, never a 200 that changed nothing.
enum ChannelDigestAPI {
    static let path = "/api/account/channel-digest"

    static func set(_ optIn: Bool) async throws -> Bool {
        struct Body: Encodable { let optIn: Bool }
        struct Answer: Decodable { let optIn: Bool }
        let data = try await APIClient.shared.putReturningData(path, body: Body(optIn: optIn))
        return try await APIClient.shared.decode(data, as: Answer.self).optIn
    }
}

/// Профил's switch: shown at once, put back with the reason if the server
/// refuses. Nothing here is sent by tests, CI or A11yShots.
@MainActor
@Observable
final class ChannelDigestSwitch {
    private(set) var on: Bool
    private(set) var saving = false
    private(set) var failure: String?
    /// The refusal alert's own switch.
    var showsFailure = false

    private let send: @MainActor (Bool) async throws -> Bool

    init(on: Bool, send: @escaping @MainActor (Bool) async throws -> Bool = { try await ChannelDigestAPI.set($0) }) {
        self.on = on
        self.send = send
    }

    /// A fresh `/me` answered: its value stands, unless a write is out.
    func adopt(_ value: Bool?) {
        guard let value, !saving else { return }
        on = value
    }

    func set(_ wanted: Bool) async {
        guard wanted != on, !saving else { return }
        let before = on
        on = wanted
        saving = true
        defer { saving = false }
        do {
            on = try await send(wanted)
            failure = nil
        } catch {
            on = before
            failure = UserMessage.text(for: error)
            showsFailure = true
        }
    }

    static let title = "Сутрешен обзор от каналите"
    static let note = "Всяка сутрин между 7:15 и 8:15 ще получавате обобщение на споменаванията и отговорите в каналите. Другите известия остават както са."
    static let failedTitle = "Настройката не е запазена"
}
