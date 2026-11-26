import SwiftUI
import UIKit

/// The way back from a pushed screen: an arrow pointing left, lower left,
/// see-through (owner 2026-11-19, «the back button has to go to the bottom
/// left of each page, being transparent and an arrow pointing left»).
///
/// ── Why it moved ──
///
/// The system's back button sits top left, out of a thumb's reach on a phone
/// held in one hand, and on a step of a form it sat beside «Отказ», which
/// throws the whole entry away (#609). Lower left it is where the thumb is,
/// it mirrors the assistant's button lower right (#483), and it is nowhere
/// near «Отказ».
///
/// ── Every pushed screen, at the place that pushes it ──
///
/// Applied where a screen is pushed — `RoutedStack`'s one `AppRoute`
/// destination, each `navigationDestination(for:)`, each `NavigationLink`
/// that pushes a view — never inside the screen, so a screen that is also a
/// stack's root (or a sheet's first page) never shows a way back to nowhere.
/// `FloatingBackTests` holds every push site to it.
///
/// ── What it keeps from the system's button ──
///
/// - The swipe from the left edge. Hiding the system button turns that swipe
///   off, so `UINavigationController` keeps it on below (`SwipeBack`).
/// - The place above the screen's own bottom bars: it sits `BottomChrome`'s
///   height up, as the assistant's button does, so it never covers «Запази»
///   or the five seconds of «Отмени» — in a sheet's stack as well, where the
///   screen counts its bars itself.
/// - Its name for Voice Control and VoiceOver: «Назад», and "Back".
///
/// ── `disabled` ──
///
/// While a save is under way there is no way back — not by the arrow, not by
/// the swipe — so a save does not land on a step that has gone. The arrow is
/// withdrawn rather than greyed out, as the system's button was.
///
/// A `View` around the screen rather than a `ViewModifier`: it owns a
/// main-actor `BottomChrome` in `@State`, as `RoutedStack` does.
struct FloatingBack<Screen: View>: View {
    let screen: Screen
    var disabled = false
    /// Extra height for a screen whose bottom-left corner something else
    /// must keep (`FloatingCorner.mapAttributionLift`).
    var lift: CGFloat = 0

    @Environment(\.dismiss) private var dismiss
    /// The stack's bottom bars — nil in a stack that is not a `RoutedStack`,
    /// such as a sheet's own (`TreatmentEntryFlow`).
    @Environment(BottomChrome.self) private var stackChrome: BottomChrome?
    /// This screen's own, for a stack that has none: its bars report here,
    /// so a sheet's step keeps clear of its «Запази» just the same.
    @State private var ownChrome = BottomChrome()
    /// Whether this screen is holding the swipe off right now, so a hold is
    /// counted once and always given back.
    @State private var holding = false

    var body: some View {
        let chrome = stackChrome ?? ownChrome
        screen
            .environment(chrome)
            .navigationBarBackButtonHidden(true)
            .reportsScrollDirection()
            .overlay(alignment: .bottomLeading) {
                if !disabled {
                    FloatingCornerButton(title: FloatingCornerButton.back, systemImage: "arrow.left",
                                         spoken: A11y.Spoken.back) { dismiss() }
                        .floatingCorner(chrome: chrome, lift: lift)
                        .transition(.opacity)
                }
            }
            .onAppear { hold(disabled) }
            .onChange(of: disabled) { _, now in hold(now) }
            .onDisappear { hold(false) }
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        SwipeBack.holds += on ? 1 : -1
    }
}

/// The bottom-left corner's control — the back arrow on a pushed screen,
/// «Затвори» on a sheet's first page. One look for both, the assistant's
/// size so the two lower corners match.
struct FloatingCornerButton: View {
    static let back = "Назад"
    static let close = "Затвори"

    let title: String
    let systemImage: String
    let spoken: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // THE FRAME IS INSIDE THE LABEL, and it is a MINIMUM: the glyph
            // scales with the text size, and a fixed box outside it would draw
            // the circle where the hit test is not (`ParcelTargetButton`).
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 52, minHeight: 52)
                // A LIGHT frosted disc (owner 2026-11-19: «more transparent»,
                // then «lighter frosted disc» over a bare arrow): the page
                // shows through, the material at half strength still lifts
                // the glyph off a busy background, and the glyph itself keeps
                // full contrast — it is the part that has to be read.
                .background {
                    Circle().fill(.ultraThinMaterial).opacity(FloatingCorner.discOpacity)
                }
                .overlay {
                    Circle().strokeBorder(Palette.Surface.edge.opacity(FloatingCorner.ringOpacity), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityInputLabels(spoken)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Where the corner control sits, and how see-through it is.
enum FloatingCorner {
    /// The frosted disc's strength: half of `.ultraThinMaterial`.
    static let discOpacity = 0.5
    static let ringOpacity = 0.6
    /// How far up a screen whose bottom-left corner is a map's Apple
    /// attribution puts the control: the logo sits 8 pt in and about 20 pt
    /// tall, and it must stay visible (`ParcelTargetButton`).
    static let mapAttributionLift: CGFloat = 28
}

extension View {
    /// Lower left, 16 pt in, above the stack's bottom bars, staying put while
    /// the keyboard is up — the assistant's placement, mirrored.
    func floatingCorner(chrome: BottomChrome, lift: CGFloat = 0) -> some View {
        padding(.leading, 16)
            .padding(.bottom, chrome.height + 12 + lift)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Out of the way while the page scrolls down (owner, 2026-11-26).
            .hidesWhileScrollingDown()
    }
}

/// «Затвори» on a sheet's first page, lower left (owner 2026-11-19, «move
/// the close button also to bottom … left»).
///
/// The same corner as the back arrow, and they never meet: «Затвори» is on a
/// sheet's ROOT, the arrow on what is pushed over it, and only one of those
/// is on screen at a time. `action` is the site's own — the `dismiss` it
/// already called — so which presentation closes is exactly what it was.
struct FloatingClose<Screen: View>: View {
    let screen: Screen
    var shown = true
    var lift: CGFloat = 0
    let action: () -> Void

    @Environment(BottomChrome.self) private var stackChrome: BottomChrome?
    @State private var ownChrome = BottomChrome()

    var body: some View {
        let chrome = stackChrome ?? ownChrome
        screen
            .environment(chrome)
            .reportsScrollDirection()
            .overlay(alignment: .bottomLeading) {
                if shown {
                    FloatingCornerButton(title: FloatingCornerButton.close, systemImage: "xmark",
                                         spoken: A11y.Spoken.close, action: action)
                        .floatingCorner(chrome: chrome, lift: lift)
                }
            }
    }
}

extension View {
    /// A pushed screen's way back, lower left. Apply it where the screen is
    /// pushed, not inside it (see `FloatingBack`).
    func floatingBack(disabled: Bool = false, lift: CGFloat = 0) -> some View {
        FloatingBack(screen: self, disabled: disabled, lift: lift)
    }

    /// A sheet's way out, lower left. Apply it to the sheet's first page,
    /// with the `dismiss` that page already used (see `FloatingClose`).
    func floatingClose(shown: Bool = true, lift: CGFloat = 0, action: @escaping () -> Void) -> some View {
        FloatingClose(screen: self, shown: shown, lift: lift, action: action)
    }
}

/// The edge swipe back, kept on while the system's back button is hidden.
///
/// UIKit ties the swipe to the button: `navigationBarBackButtonHidden(true)`
/// leaves the gesture's own delegate refusing every swipe. So every
/// navigation controller takes the delegate over and allows the swipe
/// whenever there is a screen to go back to — unless a `floatingBack` on
/// screen is `disabled`, which holds it off for as long as its save runs.
@MainActor
enum SwipeBack {
    /// How many screens are holding the swipe off.
    static var holds = 0

    /// Whether a swipe back may begin on a stack this deep.
    static func allows(depth: Int) -> Bool {
        depth > 1 && holds == 0
    }
}

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        return SwipeBack.allows(depth: viewControllers.count)
    }
}
