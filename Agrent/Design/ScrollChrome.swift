import SwiftUI
import UIKit

/// The floating corner buttons — «Назад»/«Затвори» lower left and Агрент lower
/// right — get out of the way while the page is read (owner, 2026-11-26):
/// "visible when scrolling up and invisible when scrolling down".
///
/// ── Why UIKit, on a SwiftUI screen ──
///
/// SwiftUI reports a scroll position per container only from iOS 18
/// (`onScrollGeometryChange`), and this app runs from iOS 17 with Lists,
/// Forms and ScrollViews on a hundred screens. Every one of them is a
/// `UIScrollView` underneath, so `ScrollDirectionProbe` finds the screen's
/// own vertical scroll view once and watches its offset: one mechanism for
/// every screen, nothing to add to each.
///
/// ── Never hidden for someone who cannot scroll it back ──
///
/// VoiceOver and Switch Control users move by element, not by flick, and a
/// button that vanished on the way down is a button they may not find again.
/// With either on, the corners stay. Full Keyboard Access has no public
/// check, and needs none: only a finger's drag or its fling hides anything
/// (`byUser` below), and a keyboard scroll is neither.
@MainActor
@Observable
final class ScrollChrome {
    static let shared = ScrollChrome()

    /// The corner buttons are out of the way.
    private(set) var hidden = false

    /// Scroll distance that counts as a direction, so a jitter of a few
    /// points while the finger rests does not flicker the buttons.
    static let hideAfter: CGFloat = 12
    static let showAfter: CGFloat = 8
    /// Near the top of a page the buttons always show.
    static let topZone: CGFloat = 40

    /// Where the current direction started. A drag reports a few points per
    /// frame, so the distance that counts is from this turning point, not
    /// from the previous frame — measured per frame, no drag would ever
    /// pass `hideAfter` and nothing would hide (which is how the first
    /// version behaved on the simulator, with every unit test green).
    private var turn: CGFloat?

    /// A new screen came up: its corners show until it is scrolled.
    func reset() {
        turn = nil
        if hidden { hidden = false }
    }

    /// One offset reading from the visible screen's scroll view. Only a
    /// person's own drag or its fling counts — a page loading its content
    /// moves the offset too, and must not hide anything.
    func scrolled(to offset: CGFloat, topInset: CGFloat, byUser: Bool) {
        let y = offset + topInset
        guard !Self.assistiveTechnologyRunning else { return reset() }
        if y <= Self.topZone {
            if hidden { hidden = false }
            turn = y
            return
        }
        guard byUser, let start = turn else {
            turn = y
            return
        }
        if hidden {
            // Hidden: going further down only moves the turning point.
            let lowest = max(start, y)
            if lowest - y > Self.showAfter {
                hidden = false
                turn = y
            } else {
                turn = lowest
            }
        } else {
            let highest = min(start, y)
            if y - highest > Self.hideAfter {
                hidden = true
                turn = y
            } else {
                turn = highest
            }
        }
    }

    static var assistiveTechnologyRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
}

extension View {
    /// A corner button that steps aside while the page scrolls down.
    func hidesWhileScrollingDown() -> some View {
        modifier(HidesWhileScrollingDown())
    }

    /// Watches this screen's vertical scroll view for `ScrollChrome`.
    func reportsScrollDirection() -> some View {
        background(ScrollDirectionProbe().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct HidesWhileScrollingDown: ViewModifier {
    @State private var chrome = ScrollChrome.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hidden means NOT RENDERED, not transparent. A transparent button with
    /// `.accessibilityHidden` stayed in the accessibility tree (measured on
    /// the simulator), so Voice Control could still press a button nobody
    /// can see. Removing it settles that, and the transition keeps the slide.
    func body(content: Content) -> some View {
        ZStack {
            if !chrome.hidden {
                content
                    // Slides down out of the way; with Reduce Motion only fades.
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 24)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.hidden)
    }
}

/// Finds the screen's own scroll view and reports its offset. Placed in the
/// screen's background, so its nearest view controller is the one hosting
/// that screen, and the scroll views under that controller's view are the
/// screen's — not a pushed screen's, which has its own controller.
private struct ScrollDirectionProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private var observation: NSKeyValueObservation?
        private weak var watched: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                observation = nil
                watched = nil
                return
            }
            ScrollChrome.shared.reset()
            attach()
            // Lists and Forms build their rows lazily: look again once the
            // first layout has happened, in case the scroll view came later.
            Task { @MainActor [weak self] in
                for delay in [300, 700] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self, self.window != nil, self.watched == nil else { return }
                    self.attach()
                }
            }
        }

        private func attach() {
            guard let root = hostingView(), let scroll = Self.mainScrollView(in: root) else { return }
            guard scroll !== watched else { return }
            watched = scroll
            observation = scroll.observe(\.contentOffset, options: [.new]) { scrollView, _ in
                MainActor.assumeIsolated {
                    ScrollChrome.shared.scrolled(
                        to: scrollView.contentOffset.y,
                        topInset: scrollView.adjustedContentInset.top,
                        byUser: scrollView.isDragging || scrollView.isDecelerating)
                }
            }
        }

        /// The nearest view controller's view: the screen this probe is on.
        private func hostingView() -> UIView? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller.view }
                responder = next
            }
            return nil
        }

        /// The tallest vertically scrolling view on the screen — the page,
        /// not a row of chips or a picker wheel inside it.
        static func mainScrollView(in root: UIView) -> UIScrollView? {
            var best: UIScrollView?
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let scroll = view as? UIScrollView, !(scroll is UITextView),
                   scroll.bounds.height > (best?.bounds.height ?? 120),
                   scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height
                    || scroll.bounds.width >= root.bounds.width * 0.8 {
                    best = scroll
                }
                queue.append(contentsOf: view.subviews)
            }
            return best
        }
    }
}
