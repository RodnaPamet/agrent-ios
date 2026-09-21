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
    case stale(since: Date)

    /// "преди 5 минути", or nil when the data came straight off the network.
    ///
    /// Forced to bg_BG rather than the device locale: every other string on
    /// these screens is Bulgarian, and this one is glued to them. The device
    /// here reports en-BG, which would otherwise render
    /// "данни отпреди 5 minutes ago".
    var ageDescription: String? {
        guard case .stale(let since) = self else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "bg_BG")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: since, relativeTo: Date())
    }
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
}
