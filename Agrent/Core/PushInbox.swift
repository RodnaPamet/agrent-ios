import Observation

/// A tapped notification on its way to its screen (agrent-ios#368).
///
/// iOS hands the tap to the application delegate, which knows nothing of
/// farms or tabs. So the delegate leaves the link here, and the screens take
/// it once they can show it:
///
///   1. `FarmGate` opens the link's farm, when it is one of the person's
///      and isn't open already.
///   2. The tabs built for that farm (`MainTabView`) open the screen, and
///      take the link.
///
/// ── For the session it arrived in ──
///
/// Kept with the session epoch it arrived under. A link that came while
/// nobody was signed in, or for whoever signed out since, names another
/// person's farm and task, and is dropped rather than opened for whoever
/// signs in next. Изход also empties it (`SessionReset`).
@Observable
@MainActor
final class PushInbox {
    static let shared = PushInbox()

    struct Pending: Equatable {
        let link: PushLink
        let epoch: Int
    }

    private(set) var pending: Pending?

    /// A notification was tapped. The latest tap wins: it is what the
    /// person just asked for, so one the app can't show clears an earlier
    /// link rather than letting it open later in its place.
    func receive(link: String?) {
        pending = PushLink.parse(link).map { Pending(link: $0, epoch: SessionEpoch.current) }
    }

    /// The link waiting to be shown in THIS session, if any.
    var current: PushLink? {
        guard let pending, SessionEpoch.isCurrent(pending.epoch) else { return nil }
        return pending.link
    }

    /// What `farm`'s tabs should open, taking it so it opens once.
    func take(in farm: String) -> PushLink? {
        guard let link = current, link.farm == farm else { return nil }
        pending = nil
        return link
    }

    /// The link can't be shown: its farm isn't the person's.
    func drop() { pending = nil }

    /// Изход: nothing of the last person's is opened for the next.
    func reset() { pending = nil }
}
