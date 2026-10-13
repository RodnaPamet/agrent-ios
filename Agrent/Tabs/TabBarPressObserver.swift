import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Finishes a press on a bottom-bar icon that the system bar took and did
/// not act on (agrent-ios#305).
///
/// ── The defect, which is iOS's ──
///
/// On iOS 27.0.1 a quick tap on a tab-bar icon in the strip above the home
/// indicator lights the icon and selects nothing. Measured on the owner's
/// iPhone 17 with every touch near the bar traced: 86 presses on an icon, 76
/// selected, 10 did not — all ten in one rectangle, about x 145–275 and
/// y ≥ 835 of a 402 × 874 pt screen, the label line of the three middle icons.
/// Every press above it selected, and so did presses as low on the two outer
/// icons. On a miss nothing reaches the app: no write of the selection, and
/// UIKit's own `selectedIndex` does not move. The App Store's bar misses in
/// the same place, so it is not this app's bar that is at fault — and it is
/// where a thumb lands.
///
/// ── What this does ──
///
/// WATCHES, and never recognises. It sits on the window, sees a touch come
/// down on a bar icon and lift again as a tap, and gives the bar
/// `TabPress.grace` to write the selection. When the bar has written nothing
/// by then, the app selects that tab itself (`AppRouter.finishPress`). When
/// the bar did answer — every press outside that strip, and every press on
/// an iOS without the defect — this does nothing at all.
///
/// A recogniser that never leaves `.possible` cannot cancel, delay or outrank
/// another one, the bar's own included: it fails itself when the touch ends,
/// and at once for a touch that is not on a bar icon.
///
/// ── Which icon ──
///
/// No private class is named. The touched view is followed up to the first
/// view that is one of exactly as many of its own kind, side by side, as the
/// bar has tabs — and that sits inside a `UITabBar`. Its place in that row,
/// left to right, is the tab's place on the bar. A bar built any other way
/// yields no icon, and then nothing is ever finished: the fallback's own
/// failure is the system's behaviour, never a wrong tab.
final class TabBarPressObserver: UIGestureRecognizer {
    weak var router: AppRouter?

    private var press: TabPress?
    /// Counts touches that came down, so a press is finished only while it
    /// is still the last thing the person did.
    private var touches = 0

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches += 1
        press = nil
        guard let router, touches.count == 1, event.allTouches?.count == 1, let touch = touches.first,
              let index = Self.iconIndex(of: touch.view, among: router.bar.count) else {
            state = .failed
            return
        }
        press = TabPress(index: index, writesBefore: router.selectionWrites,
                         began: touch.timestamp, start: touch.location(in: nil))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        defer {
            press = nil
            state = .failed
        }
        guard let press, let touch = touches.first,
              press.isTap(endingAt: touch.location(in: nil), time: touch.timestamp) else { return }
        let lifted = self.touches
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: TabPress.grace)
            guard let self, self.touches == lifted, let router = self.router,
                  press.isUnanswered(writesNow: router.selectionWrites),
                  router.bar.indices.contains(press.index) else { return }
            router.finishPress(on: router.bar[press.index])
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        press = nil
        state = .failed
    }

    /// The place on the bar of the icon `view` is, or is part of — nil for a
    /// view that is not on a tab bar, or a bar whose icons cannot be counted.
    static func iconIndex(of view: UIView?, among count: Int) -> Int? {
        var candidate = view
        while let current = candidate, !(current is UITabBar) {
            let row = current.superview?.subviews.filter { type(of: $0) == type(of: current) && !$0.isHidden } ?? []
            if row.count == count, count > 1, isOnATabBar(current) {
                let leftToRight = row.sorted { $0.frame.minX < $1.frame.minX }
                return leftToRight.firstIndex(of: current)
            }
            candidate = current.superview
        }
        return nil
    }

    private static func isOnATabBar(_ view: UIView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is UITabBar { return true }
            ancestor = current.superview
        }
        return false
    }
}

/// Puts a `TabBarPressObserver` on the window the tabs are in, once, and
/// points it at the router of the tabs on screen — `FarmGate` rebuilds the
/// tabs, and their router, for every farm.
struct TabBarPressCatcher: UIViewRepresentable {
    let router: AppRouter

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.router = router
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.router = router
        anchor.attach()
    }

    final class Anchor: UIView {
        weak var router: AppRouter?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard let window else { return }
            let observer = window.gestureRecognizers?.lazy.compactMap { $0 as? TabBarPressObserver }.first
                ?? {
                    let observer = TabBarPressObserver()
                    window.addGestureRecognizer(observer)
                    return observer
                }()
            observer.router = router
        }
    }
}
