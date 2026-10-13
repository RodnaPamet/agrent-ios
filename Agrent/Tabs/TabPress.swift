import CoreGraphics
import Foundation

/// One press on a bottom-bar icon, from the finger coming down to the moment
/// the app decides whether the bar answered it (agrent-ios#305).
///
/// A value with no UIKit in it, so `TabPressTests` can hold the rule:
/// `TabBarPressObserver` only feeds it touches.
struct TabPress: Equatable {
    /// Which icon, counted from the leading edge of the bar.
    let index: Int
    /// `AppRouter.selectionWrites` when the finger came down.
    let writesBefore: Int
    let began: TimeInterval
    let start: CGPoint

    /// How long the bar is given to answer after the finger lifts. On the
    /// phone its write came 3–30 ms after the lift; five times the slowest.
    static let grace: Duration = .milliseconds(150)
    /// Longer than this is a hold, which on iOS 26 lifts the icon to be
    /// dragged along the bar — the bar's gesture, and it does answer those.
    static let longest: TimeInterval = 0.5
    /// Further than this is a slide to another icon.
    static let slop: CGFloat = 12

    /// A tap: short, and lifted where it came down.
    func isTap(endingAt point: CGPoint, time: TimeInterval) -> Bool {
        time - began < Self.longest && hypot(point.x - start.x, point.y - start.y) < Self.slop
    }

    /// The bar has written nothing since the finger came down, so the press
    /// is the app's to finish.
    func isUnanswered(writesNow: Int) -> Bool {
        writesNow == writesBefore
    }
}
