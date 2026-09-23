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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: outbox.refused.isEmpty
                      ? "tray.and.arrow.up" : "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let first = outbox.pending.first {
                        Text(first.parcelSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if outbox.isFlushing {
                    ProgressView().controlSize(.small)
                } else if outbox.refused.isEmpty {
                    Button("Изпрати") { Task { await outbox.flush() } }
                        .font(.footnote.weight(.medium))
                }
            }
            .font(.footnote)
            .foregroundStyle(outbox.refused.isEmpty ? Color.primary : Color.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
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
