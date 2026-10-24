import SwiftUI

/// «Коригирай», step two: each change read back, what it was and what it
/// becomes, before «Запази» (agrent-ios #392).
///
/// Only the changes, unlike «Ново мероприятие»'s «Проверка», which reads the
/// whole treatment back. Here the rest stays as recorded, and a list of
/// everything would hide the one line that moves. A change to a filed
/// record is checked here, as a new entry is there.
struct TreatmentCorrectionCheckView: View {
    let draft: TreatmentCorrection.Draft
    let saving: Bool
    let failure: String?
    /// Someone else corrected it meanwhile: «Запази» can't go out, and the
    /// way on is to load what is there now.
    let stale: Bool
    let onSave: () -> Void
    let onReload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        PageForm {
            Section {
                ForEach(draft.changes) { change in
                    ChangeRow(change: change)
                }
            } header: {
                SectionHeader("Промени")
            }

            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    if stale {
                        Button(TreatmentCorrection.reloadTitle, action: onReload)
                            .accessibilityInputLabels(A11y.Spoken.reload)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actions }
        .inlineTitle("Проверка")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отказ", action: onCancel)
                    .disabled(saving)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
        }
        // A save under way is not abandoned by a swipe back, and its refusal
        // does not land on a screen that has gone.
        .navigationBarBackButtonHidden(saving)
        // Said, not only drawn: the refusal replaces the spinner under the
        // cursor.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            var line = AttributedString(now)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Text(TreatmentCheckView.finalNote)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSave) {
                if saving {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Записване")
                } else {
                    Text("Запази").frame(maxWidth: .infinity)
                }
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(saving || stale)
            .accessibilityInputLabels(A11y.Spoken.save)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }
}

/// One change: the field, then what it was and what it becomes, each on its
/// own line so neither is cut at the larger text sizes.
private struct ChangeRow: View {
    let change: TreatmentCorrection.Draft.Change

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
            Text("Беше: \(change.before ?? "—")")
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Става: \(change.after ?? "—")")
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop, said as a sentence: a dash is read as nothing at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(change))
    }

    nonisolated static func spoken(_ change: TreatmentCorrection.Draft.Change) -> String {
        "\(change.label): беше \(change.before ?? "няма"), става \(change.after ?? "няма")"
    }
}
