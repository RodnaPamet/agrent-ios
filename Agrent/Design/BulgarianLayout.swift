import UIKit

/// Makes UIKit measure Bulgarian the way it draws it.
///
/// ── The defect ──
///
/// On a device whose region is Bulgaria, UIKit-drawn text truncates far
/// short of its available width. Measured on iOS 26.5, in this app:
///
///   - the confirmation button on the insurance ask — the app's only
///     unundoable write — drew «Изпрат...питване» in a button more than
///     half empty;
///   - an inline navigation title «Ивова земя» drew «Ивова зе…» with a
///     third of the bar empty on either side.
///
/// It is not a width problem and not a length problem. A TWENTY-SEVEN
/// character Bulgarian title rendered whole where a ten-character one did
/// not, and «Ivova zemya» — eleven Latin characters, WIDER on screen than
/// the Bulgarian string that truncated — rendered whole. The same strings
/// under `-AppleLanguages "(en)"` and `"(ru)"` all render whole.
///
/// Bulgarian is the one language where SF Pro substitutes different shapes
/// for и, п, д, г and т. Measured before that substitution and drawn after
/// it, every string comes out wider than the slot computed for it. That
/// last sentence is inference; everything above it is in screenshots.
///
/// ── The fix, and why it looks like superstition ──
///
/// Laying out one throwaway `UIAlertController` at launch fixes BOTH
/// surfaces for the life of the process. Same build, same string, same
/// screen, the only difference being this call:
///
///     without   «Изпрат...питване»
///     with      «Изпрати запитване»
///
/// and a raw `.navigationTitle("Ивова земя")` — with no `inlineTitle`
/// helper — goes from «Ивова зе…» to whole.
///
/// The mechanism is not documented anywhere I can point to. What the
/// evidence supports is narrow: the first alert layout in a process primes
/// something the text system otherwise gets wrong, and priming it
/// deliberately at launch is cheaper than every later string paying for it.
/// That is a description of the experiment, not an explanation, and this
/// comment should not pretend otherwise.
///
/// ── What this does NOT replace ──
///
/// `View.inlineTitle(_:)` stays. It solves the same defect a second way,
/// by keeping the title out of UIKit's hands entirely, and if this trick
/// ever stops working under an OS update the titles keep their protection
/// while the alerts lose theirs. Belt and braces, on the one screen where
/// the braces are a button that cannot be undone.
enum BulgarianLayout {

    /// Idempotent. Called from `AgrentApp.init()`, before any scene exists.
    @MainActor
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Both styles, because they lay out differently and it costs
        // nothing to prime the one the app does not currently use.
        for style in [UIAlertController.Style.alert, .actionSheet] {
            let controller = UIAlertController(
                // Deliberately NOT strings the app displays. Nothing here
                // reaches a screen; these exist to be measured. Cyrillic
                // with и, п, д, г and т in it is the whole requirement.
                title: "Подготовка на оформлението",
                message: "Изречение на български, което никъде не се показва.",
                preferredStyle: style)
            controller.addAction(UIAlertAction(title: "Потвърждавам действието", style: .default))
            controller.addAction(UIAlertAction(title: "Отмяна на действието", style: .cancel))

            // A frame and a forced layout pass. Without the layout the
            // controller's view is never asked to measure anything and the
            // call does nothing at all.
            controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }

    @MainActor
    private(set) static var isInstalled = false

    /// Tests only — `install()` is once per process by design.
    @MainActor
    static func resetForTesting() { isInstalled = false }
}
