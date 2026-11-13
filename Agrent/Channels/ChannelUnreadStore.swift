import Observation

/// How many new posts wait in the channels a person has joined (#597,
/// agri-saas #2990), for the badge on each channel and the total beside
/// «Канали» in the menu.
///
/// The server counts TOP-LEVEL posts by others since the person's read
/// cursor (or since they joined), and none that were removed; a channel not
/// joined has no count at all (`unreadCount: null`), never a 0. Replies reach
/// the person through the mention and reply push instead.
///
/// Refreshed with Борса's badge — at launch and on every return to the app —
/// and whenever «Канали» loads its list; lowered at once when a feed is read.
@Observable
@MainActor
final class ChannelUnreadStore {
    static let shared = ChannelUnreadStore()

    private(set) var counts: [String: Int] = [:]

    var total: Int { counts.values.reduce(0, +) }

    func count(for channel: Channel) -> Int? { counts[channel.id] ?? channel.unreadCount }

    func refresh() async {
        guard FeatureFlags.shared.isOn(ChannelsAPI.flag) else { return }
        let epoch = SessionEpoch.current
        guard let channels = try? await ChannelsAPI.channels() else { return }
        apply(channels, asOf: epoch)
    }

    /// `asOf` is required: a list fetched for the account that just signed
    /// out must not land on the next one.
    func apply(_ channels: [Channel], asOf epoch: Int) {
        guard SessionEpoch.isCurrent(epoch) else { return }
        counts = Dictionary(channels.compactMap { channel in channel.unreadCount.map { (channel.id, $0) } },
                            uniquingKeysWith: { _, last in last })
    }

    func markedRead(_ channelID: String) {
        if counts[channelID] != nil { counts[channelID] = 0 }
    }

    /// No badge — part of `SessionReset`.
    func reset() {
        counts = [:]
    }
}
