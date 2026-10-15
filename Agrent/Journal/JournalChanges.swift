import Observation

/// The journal list's cue to read again after a change made on a screen
/// pushed above it (#326).
///
/// The entry's screen is reached by value (`AppRoute.journalEntry`), so it
/// can't be handed the list's store or a closure to call. Until an
/// administrator could abandon a treatment from it, that screen changed
/// nothing, so nothing was needed. Now the list would go on showing a
/// treatment the server has removed, until a pull.
///
/// Holds a counter and no user data, so sign-out leaves it alone
/// (`SignOutHygieneTests.notReset`).
@MainActor
@Observable
final class JournalChanges {
    static let shared = JournalChanges()

    private(set) var revision = 0

    func changed() { revision &+= 1 }
}
