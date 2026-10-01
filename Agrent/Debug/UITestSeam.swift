#if DEBUG
import Foundation

/// THE ONE SWITCH that lets a UI test reach a screen behind sign-in.
///
/// ── What it is for, and what it is NOT ──
///
/// `A11yShots/A11yShotsTests.swift` photographs real screens, and since
/// agrent-ios#115 it does so THROUGH this seam: it launches with
/// `launchArgument` and every capture is a render of `Tests/Fixtures`. Before
/// that it could only run on a simulator somebody had already signed in on,
/// against production, because the app
/// opens on `SignInView` unless `TokenStore.load()` finds tokens
/// (`AgrentApp.swift`), and sign-in runs through `ASWebAuthenticationSession`
/// against Google. A GitHub runner's simulator is new every run, so its
/// Keychain is empty and the suite cannot reach a single screen. That is why
/// `project.yml` keeps `AgrentA11yShots` out of the `Agrent` scheme.
///
/// This is the seam that removes that reason. It does TWO things and nothing
/// else:
///
///   1. `AgrentApp` renders `MainTabView` instead of `SignInView`.
///   2. `APIClient` serves every request from `FixtureURLProtocol` and hands
///      out `stubTokens` instead of reading the Keychain.
///
/// Both halves are needed and the first alone is a trap. A stub TOKEN gets
/// you past the sign-in screen and then every screen shows a network
/// failure, because the token is not one the server issued — so the
/// "screenshot fixture data" this was asked for needs the HTTP layer served
/// from fixtures too. The option as it was put to the owner did not say that;
/// it is said here.
///
/// ── Why an argument with NO leading dash ──
///
/// `NSUserDefaults` parses the argument list into its `NSArgumentDomain`:
/// anything spelled `-key value` becomes a defaults key for the life of the
/// process. `AGRENT_UITEST_FIXTURES` carries no dash, so it is a token
/// `ProcessInfo` can see and `UserDefaults` cannot mistake for a preference.
/// A seam that quietly installs a defaults key is a seam that changes more
/// than it says it does.
///
/// ── Why `#if DEBUG` is not the whole guarantee ──
///
/// The file is inside `#if DEBUG`, AND `project.yml` excludes
/// `Agrent/Debug/*` from the Release configuration's source list
/// (`EXCLUDED_SOURCE_FILE_NAMES`). Two mechanisms because they fail
/// differently: a `#if` is defeated by somebody defining `DEBUG` in a
/// Release-adjacent configuration, and a build-setting exclusion is defeated
/// by somebody adding a file outside this directory. The CI step "The UI test
/// seam cannot reach Release" holds both against the tree.
///
/// ── What it costs a normal run ──
///
/// Nothing. `isActive` is one `ProcessInfo.arguments.contains` evaluated once
/// per process, and a debug build launched from Xcode passes no such argument,
/// so `AgrentApp` takes the same branch it always did and `APIClient` builds
/// the same `URLSessionConfiguration` it always did.
///
/// ── What it costs the simulator you point it at ──
///
/// Read this before running it anywhere but a throwaway device. The app under
/// the seam still writes `ResponseCache` to `Library/Caches` — fixture bytes.
/// Since agri-saas#1191 P0.9 they are keyed on the FIXTURE user's id
/// (`CacheScope`; under the seam `SessionIdentity` is memory-only and learns
/// that id from the fixture `/me`), so they no longer overwrite the owner's
/// real entries — they sit beside them and age out under the byte budget.
/// Nothing here touches the Keychain (that was the reason for `stubTokens`
/// rather than planting a token), so the session itself survives.
enum UITestSeam {
    /// The token `A11yShotsTests` adds to `app.launchArguments`.
    ///
    /// Spelled once in the app, here, and read by the CI guard as well — a
    /// launch argument that exists as two string literals is a launch
    /// argument that will eventually be two different strings. The ONE copy
    /// is `A11yShotsTests.seamArgument`, because a UI test target runs in its
    /// own process and cannot link the app; it points back here, and a
    /// mismatch fails that suite at its first assertion (the app would open
    /// on `SignInView`).
    static let launchArgument = "AGRENT_UITEST_FIXTURES"

    /// Resolved ONCE, at first use, from the argument vector this process was
    /// launched with.
    ///
    /// `static let` rather than a computed property on purpose: the answer
    /// cannot change during a process's life, and `APIClient`'s session is
    /// built from it inside a closure that must not be able to disagree with
    /// the branch `AgrentApp` took a moment earlier.
    static let isActive: Bool =
        ProcessInfo.processInfo.arguments.contains(launchArgument)

    /// Tokens that never leave the device.
    ///
    /// `FixtureURLProtocol` answers every request before URLSession opens a
    /// socket, so this value is never presented to anything — it exists
    /// because `APIClient.currentTokens()` throws `notSignedIn` when the
    /// Keychain is empty, which is every request on a fresh simulator.
    ///
    /// `distantFuture` so `Tokens.isExpired` is false and the refresh path is
    /// never entered. A refresh under the seam would be answered by the
    /// fixture protocol with `NO_FIXTURE`, `TokenStore.clear()` would NOT run
    /// (only a 401 clears — see `APIClient.refresh`), and the screenshot
    /// would be of a screen mid-retry. Cheaper to make it unreachable.
    static let stubTokens = Tokens(
        accessToken: "fixture-access-token",
        refreshToken: "fixture-refresh-token",
        expiresAt: .distantFuture
    )
}
#endif
