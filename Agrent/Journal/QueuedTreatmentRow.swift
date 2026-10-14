import SwiftUI

/// A «Нов запис» treatment kept on the phone, not on the server yet (#324).
///
/// The journal shows it at once, as the web shows its queued one (agri-saas
/// #1841): a farmer who saved in a field with no signal looks here next, and
/// an entry missing from the register reads as lost — and gets typed again,
/// under a new key, as a second treatment.
///
/// Not a link. The entry's own screen offers «Изтегли PDF», and the server
/// has no pages for a handle it has not seen. Delivery reloads the list, and
/// the server's row, with its document, takes this one's place.
///
/// Built from what the row carries (`PendingOperation.QueuedTreatment`),
/// never by decoding the request body it will send.
struct QueuedTreatmentRow: View {
    let item: PendingOperation
    let treatment: PendingOperation.QueuedTreatment

    private var kind: String { treatment.treatmentKind?.label ?? treatment.kind }
    private var parcels: String { Plural.bg(treatment.parcelCount, "парцел", "парцела") }
    private var blocks: String? {
        treatment.blockNames.isEmpty ? nil : treatment.blockNames.joined(separator: ", ")
    }

    /// Waiting for signal, or refused: the two need opposite things from the
    /// farmer — one needs nothing, the other a person to read it — so they
    /// are never said the same way (`PendingOperation.isRefused`).
    private var status: String {
        guard item.isRefused else { return Self.waiting }
        return item.lastError ?? Self.refused
    }

    static let waiting = "Чака изпращане"
    static let refused = "Сървърът не прие записа."

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(treatment.productName)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                MetaRow {
                    Text(kind)
                    MetaSeparator()
                    Text(parcels)
                    if let area = treatment.area {
                        MetaSeparator()
                        Text(area.text)
                    }
                }
                if let blocks { Text(blocks) }
                if let day = treatment.day { Text(BgDate.dayMonth(day)) }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Label(status, systemImage: item.isRefused ? "exclamationmark.triangle" : "tray.and.arrow.up")
                .font(.footnote)
                .foregroundStyle(item.isRefused ? Palette.warning : Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        // One stop, spoken from the values, as `JournalRow` is: the area in
        // «декара», never the «дка» VoiceOver spells, and no separators.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            treatment.productName, kind, parcels, treatment.area?.spoken, blocks,
            treatment.day.map(BgDate.full), status,
        ]))
    }
}
