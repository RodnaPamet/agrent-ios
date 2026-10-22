import Foundation

/// The build a person is running, as TestFlight names it: «0.1.0 (5.1)»
/// (agrent-ios#393).
///
/// On 2026-10-22 the owner updated from TestFlight and saw no change, because
/// the build with the fix was still processing at Apple and the update had
/// installed the one before it. The app said its version nowhere, so the only
/// way to tell was to open TestFlight. «Профил» now says it.
///
/// `CFBundleShortVersionString` is the marketing version. `CFBundleVersion` is
/// the build: the TestFlight workflow sets `CURRENT_PROJECT_VERSION` to
/// `<run>.<attempt>`, and a local build keeps project.yml's `1`.
enum AppVersion {
    /// nil when the bundle has no marketing version, which a real build always
    /// has; the row is then left out rather than showing a blank.
    static func text(short: String?, build: String?) -> String? {
        guard let short = short?.trimmingCharacters(in: .whitespaces), !short.isEmpty else { return nil }
        guard let build = build?.trimmingCharacters(in: .whitespaces), !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    static let current: String? = text(
        short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
}
