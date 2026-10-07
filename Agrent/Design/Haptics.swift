import SwiftUI

/// Haptic feedback for a write the person asked for, and for nothing else
/// (agri-saas#1193 P2.8).
///
/// ── THE VOCABULARY: TWO WORDS ──
///
///   - `.success` — a write the person started has landed: the server took
///     it, or (the operation outbox only) the device is holding it to send.
///   - `.warning` — a write the person started did NOT land, and the screen
///     now says what to do about it: retry, reload, wait, fix.
///
/// There is no selection tick on pickers or segments, no tap on a button,
/// nothing on navigation, scrolling or pull-to-refresh. The web, whose event
/// set this mirrors (`src/lib/haptics.ts`), fires on action completion —
/// a field operator marking a job done, a photo uploaded — and on nothing a
/// person merely looks at or chooses between. Its pull-to-refresh tick is
/// already given here by the system's own refresh control.
///
/// ── NEVER FROM THE APP'S OWN WORK ──
///
/// A poll, a refresh, a cache revalidation or an outbox drain never changes
/// a `WriteFeedback`. A phone that buzzes in a pocket because a conversation
/// polled, or because a queued operation went out on reconnect, has told the
/// person about something they did not do. Only the code path that runs
/// because of a tap — `save`, `send`, `setStatus`, `mark` — records an outcome, and
/// `HapticSiteTests` holds the list of those paths to exactly this.
///
/// ── THE SITES, and why only these ──
///
///   1. A spray or fertiliser operation saved, or kept for later
///      (`ParcelMapView` / `ParcelOperationSheet`). The web's own haptic
///      moment: field work, often with gloves and no signal, where the sheet
///      closing is easy to miss.
///   2. A task's status changed (`TaskDetailView`) — the other half of field
///      work, beside site 5.
///   3. A message sent (`ConversationView`). The bubble appears only when
///      the refetch brings the stored text, so the tap is otherwise followed
///      by nothing for a moment.
///   4. The farm profile saved (`FarmProfileView` / `FarmProfileEditView`).
///   5. A parcel line of a field operation marked (`FieldOperationSection`
///      ← `FieldOperationStore.mark`, agrent-ios#138) — the web's own haptic
///      moment, ported at last. `.success` for a «Готово» that landed or is
///      kept on the phone to send, as for site 1; `.warning` for a refusal
///      or a conflict. Skip and reopen play nothing: the web gives them a
///      `tap`, and this vocabulary has no tap. A conflict the DRAIN parks
///      plays nothing either — the operator is not looking at it.
///
/// The other writes — a cost, a listing, a journal entry, a product, an
/// insurance request, a member invitation — close onto a list that shows the
/// new row, which is its own confirmation, and none is work done in a field.
/// Adding one is a line at its call site and a line in `HapticSiteTests`;
/// fewer is the point, so each needs its own reason.
///
/// ── THE SYSTEM DECIDES WHETHER, AND HOW HARD ──
///
/// No intensity overrides and no in-app switch. iOS's "System Haptics"
/// setting already silences `.sensoryFeedback`, on the device the person is
/// holding. The web's on/off lives in browser storage only — no API carries
/// it — so there is nothing for an app switch to agree with.
///
/// ── WHERE THE MODIFIER SITS ──
///
/// On the view that is still on screen when the outcome lands. A sheet that
/// closes on success fires its success from the screen underneath (fed by
/// `onSaved` or the store), and its refusal from itself, because a refused
/// sheet stays open.
struct WriteFeedback: Equatable {
    enum Outcome: Equatable {
        case saved
        case refused
    }

    /// The latest outcome; nil until the first one.
    private(set) var outcome: Outcome?

    /// Bumped on every outcome, so a second save after a first one is a
    /// CHANGE and fires again. Without it two successes in a row compare
    /// equal and the second is silent.
    private(set) var count = 0

    mutating func saved() {
        outcome = .saved
        count += 1
    }

    mutating func refused() {
        outcome = .refused
        count += 1
    }

    /// What the outcome feels like — the whole vocabulary, in one place.
    var feedback: SensoryFeedback? {
        switch outcome {
        case .saved: .success
        case .refused: .warning
        case nil: nil
        }
    }
}

extension View {
    /// Play `feedback`'s latest outcome when it changes. The only place in
    /// the app that calls `.sensoryFeedback` — see `WriteFeedback`.
    func writeFeedback(_ feedback: WriteFeedback) -> some View {
        sensoryFeedback(trigger: feedback) { _, new in new.feedback }
    }
}
