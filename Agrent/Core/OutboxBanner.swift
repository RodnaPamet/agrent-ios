import SwiftUI

/// "You have work that has not reached the server yet."
///
/// ── Why this is global and not on the Locations screen ──
///
/// The farmer who needs it recorded a spray in a field with no signal,
/// drove home, and opened the app — possibly on a different tab, possibly
/// days later. A banner on the screen where the work was created is a
/// banner they have no reason to return to. Unsent work is a property of
/// the app, so it is shown by the app.
///
/// It is absent when the outbox is empty, which is almost always. A
/// permanent indicator that usually says "nothing" trains people not to
/// read it.
struct OutboxBanner: View {
    @State private var outbox = OutboxStore.shared

    var body: some View {
        if !outbox.pending.isEmpty {
            // Read ONCE per render. It reads the clock, and three separate
            // reads could straddle the server's moment — a caption shown
            // beside the button it exists to replace.
            let caption = pauseCaption
            // ── NEVER TALLER THAN THE SPACE IT IS OFFERED ──
            //
            // Nothing bounded this banner's height, and it sits above EVERY
            // tab. With the pause caption at accessibility5 it took 592 of the
            // 714 points above a portrait tab bar and left the tab 122 — its
            // large title and no rows — and in landscape it left 42. Measured
            // with this file compiled against stand-ins for the store, inside
            // `MainTabView`'s stack, on the iPhone 17e simulator.
            //
            // So the row is shown whole when it fits the height the stack
            // offers, and scrolls inside that height when it does not. The
            // stack offers it half, and the tab keeps the rest: 332 points in
            // portrait, 141 in landscape. At Large and xxxLarge nothing moved,
            // in any state or orientation; at accessibility3 only the paused
            // banner in portrait, by 4 points, which now scrolls where it used
            // to cut the parcel line.
            //
            // THE COST, taken knowingly: at accessibility5 the end of the row
            // sits below the banner's own fold — for the pause caption, all
            // but its first word in portrait and all of it in landscape. The
            // scroll view flashes its indicators when it appears, and
            // VoiceOver reads the whole description either way. The caption
            // above the parcel line, or a shorter one at these sizes, would
            // bring it up; both are the owner's call.
            ViewThatFits(in: .vertical) {
                row(caption: caption)
                ScrollView { row(caption: caption) }
                    .scrollIndicatorsFlash(onAppear: true)
            }
            .font(.footnote)
            .foregroundStyle(outbox.refused.isEmpty ? Color.primary : Palette.warning)
            .background(.bar)
            // COMBINE THE TEXT, LEAVE THE BUTTON ALONE.
            //
            // `children: .combine` on the whole row folded «Изпрати» into one
            // concatenated name with the headline and the parcel summary. The
            // ACTION survived — unlike `.ignore`, combine keeps it — but the
            // NAME did not: a Voice Control user saying «Изпрати» matched
            // nothing, because no element was called that any more.
            //
            // This banner is how unsent field records leave the device once
            // signal returns, and it floats over whatever tab the farmer is
            // on. Combining is still right for the descriptive half; it was
            // never right for the control.
            .accessibilityElement(children: .contain)
        }
    }

    /// Icon, description, control — built once for each of the two shapes
    /// above, which differ only in whether they scroll.
    private func row(caption: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: outbox.refused.isEmpty
                  ? "tray.and.arrow.up" : "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = outbox.pending.first {
                    // Fixed like its two siblings. It was the one line left
                    // flexible, so it was the one that gave way when the
                    // column ran short — at accessibility3 the caption cut it
                    // to «Горната нива до…», and which field is waiting is
                    // what a farmer reads this line for. The scroll above now
                    // gives the column every point it asks for; this keeps it
                    // whole should the row ever be laid out short again.
                    Text(first.parcelSummary)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // One stop for the description, built from the values — the
            // button beside it stays a separate, nameable element.
            //
            // The pause caption is IN the sentence. While it shows there
            // is no «Изпрати», and a control that simply vanished says
            // nothing to VoiceOver; the caption is the reason, so it is
            // what gets read.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.sentence(
                [headline, outbox.pending.first?.parcelSummary, caption]))
            Spacer(minLength: 8)
            if outbox.isFlushing {
                ProgressView().controlSize(.small)
            } else if outbox.refused.isEmpty && caption == nil {
                Button("Изпрати") { Task { await send() } }
                    .font(.footnote.weight(.medium))
                    // Its own element with its own name, so «Изпрати» is
                    // both what is written and what can be said.
                    .accessibilityInputLabels(A11y.spokenNames("Изпрати", "Send"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «Изпрати», and — when the pass it starts meets a 429 — the reason,
    /// said aloud.
    ///
    /// ── The control a VoiceOver user pressed is gone ──
    ///
    /// A 429 ends the pass with the caption where the button was, and the
    /// caption's reason lives in the label of the description beside it —
    /// which VoiceOver reads only if focus happens to land there. Nothing
    /// else is spoken. So the reason is announced, on THIS path only: launch,
    /// the return to the foreground and the alarm start passes nobody is
    /// waiting on, and announcing those would talk over whatever the person
    /// is doing. High priority, because the focus move that follows a
    /// vanished control is exactly what cuts a default one short. NOT heard
    /// on a device.
    private func send() async {
        await outbox.flush()
        guard let caption = pauseCaption else { return }
        var announcement = AttributedString(caption)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// Why nothing is being sent, while the server has asked the queue to
    /// wait — and only when something is waiting to BE sent.
    ///
    /// ── It REPLACES «Изпрати», rather than sitting beside a disabled one ──
    ///
    /// A tap during the pause could only buy a guaranteed 429, so there is
    /// nothing for the button to do. A dimmed control with no reason is the
    /// worse of the two for VoiceOver and Voice Control alike: it is found,
    /// named, and does nothing. A sentence that says the queue resumes by
    /// itself is the whole of what the farmer needs.
    ///
    /// The headline stays as it is: «N операции чакат изпращане» is still
    /// true. At reopen the observed gate changes and this line goes; the
    /// alarm's own flush then shows the usual spinner, and «Изпрати» is back
    /// for whatever that pass could not send.
    private var pauseCaption: String? {
        guard !outbox.sendable.isEmpty, let remaining = outbox.pause.remaining else { return nil }
        return UserMessage.outboxRateLimited(remaining: remaining)
    }

    /// Counts, because "some operations" is not something a person can
    /// act on. And refusals are named separately — they need a person to
    /// look at them, not a better signal.
    private var headline: String {
        let refused = outbox.refused.count
        if refused > 0 {
            return "\(Plural.bg(refused, "операция", "операции")) не бяха приети от сървъра."
        }
        let waiting = outbox.sendable.count
        return "\(Plural.bg(waiting, "операция чака", "операции чакат")) изпращане."
    }
}
