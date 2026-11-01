import UIKit

/// The answer's connection, kept up for a short trip out of the app.
///
/// iOS suspends an app a few seconds after it leaves the screen, and a
/// suspended app's sockets go. The owner asked a question, switched apps to
/// send a screenshot of the wait, and came back to «Няма връзка със
/// сървъра.»: agri-saas logged the stream cancelled 4.7 s in, the model's
/// first call already answered (2026-11-01, agri-saas #2681). Holding a
/// background task while a turn's stream is open asks iOS for the usual grace
/// (about thirty seconds), which covers most answers. Past it, the turn ends
/// in `AssistantText.lostMidAnswer`.
///
/// One task per turn, ended when the turn ends, when the person stops it, or
/// when iOS says the grace is over. `application` is nil where there is no
/// app to ask, which makes this a no-op.
@MainActor
final class AssistantKeepAlive {
    private let application: UIApplication?
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(application: UIApplication? = UIApplication.shared) {
        self.application = application
    }

    /// Whether a background task is held: for the tests.
    var isHolding: Bool { task != .invalid }

    func begin() {
        guard task == .invalid, let application else { return }
        task = application.beginBackgroundTask(withName: "Асистент") { [weak self] in
            // iOS's grace is over: give the task back, or the app is killed.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        application?.endBackgroundTask(task)
        task = .invalid
    }
}
