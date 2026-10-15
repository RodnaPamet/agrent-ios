import Foundation

/// How old the data on screen is.
///
/// This exists so that a screen CANNOT show cached data without also being
/// able to say how stale it is. A cache that quietly serves yesterday's
/// numbers is worse than no cache at all: the operator cannot tell whether
/// what they are looking at is real, and a spray decision made against a
/// three-day-old field record is a regulatory problem, not a UX one.
enum Freshness: Equatable, Sendable {
    case fresh
    /// `since` is when the bytes were written on this phone, after the
    /// response arrived (`ResponseCache.read`). See there for why that's
    /// close enough.
    case stale(since: Date)
}

/// What a screen is showing, and how much to trust it.
///
/// `.failed` means there was nothing cached to fall back on — it is the
/// genuinely empty-handed case, not merely "the network call failed". A failed
/// refresh WITH a cache hit is `.loaded(value, .stale)`, because the operator
/// would rather see last week's entries labelled as last week's than a
/// blank screen with an apology on it.
enum LoadState<T: Equatable & Sendable>: Equatable, Sendable {
    case loading
    case loaded(T, Freshness)
    case failed(String)

    var value: T? {
        if case .loaded(let value, _) = self { return value }
        return nil
    }

    var freshness: Freshness? {
        if case .loaded(_, let freshness) = self { return freshness }
        return nil
    }

    /// For a screen whose SECTIONS fail independently.
    ///
    /// Every existing caller switches over the whole state, which is right when
    /// one state owns one screen. «Табло» holds four — the ag payload, the task
    /// trend, the briefing and a price series — and a block has to ask "did
    /// mine fail" without a switch that must also handle `.loading` and
    /// `.loaded` it has already handled elsewhere.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The message, for a section that reports its own failure beside the
    /// sections that loaded. Nil when nothing failed.
    var failureText: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
