import SwiftUI

/// On a treatment's entry: «Коригирано на … от …» for each correction, with
/// what each changed field said before (owner, 2026-10-22; agri-saas #2292).
///
/// The trail is for an inspector as much as for the farm: a filed register
/// that changed says so, and the earlier values stay readable. The read is
/// open to anyone who can see the treatment, unlike the correction itself.
///
/// Nothing is shown while it hasn't answered, if it can't be reached, or for
/// a treatment nobody has corrected, which is almost every one, so the
/// screen stays as it was for them. A failed read is not said: the entry's
/// own facts are what was filed, and they are on the screen either way.
struct TreatmentCorrectionsSection: View {
    /// Read by the entry's screen (`JournalDetailView.readTrail`), which
    /// draws this only when there is a correction to show. A section that
    /// read for itself would need a view to hang the read on while it had
    /// nothing to show: an empty `Group` runs no `.task`, and an empty stack
    /// adds its spacing to every treatment's page.
    let trail: TreatmentCorrectionTrail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Корекции")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(trail.corrections.enumerated()), id: \.offset) { _, entry in
                CorrectionEntry(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One correction: when and by whom, then each changed field with what it
/// was, each on its own line so nothing is cut at the larger text sizes.
private struct CorrectionEntry: View {
    let entry: TreatmentCorrectionTrail.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(TreatmentCorrection.correctedLine(entry), systemImage: "pencil")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(TreatmentCorrection.was(entry)) { was in
                VStack(alignment: .leading, spacing: 2) {
                    Text(was.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                    Text(TreatmentCorrection.wasText(was))
                        .font(.body)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop per correction, read as sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TreatmentCorrection.spoken(entry))
    }
}
