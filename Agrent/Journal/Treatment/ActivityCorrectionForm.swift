import SwiftUI

/// «Коригирай», step one, on an activity: what it was, its day, and a
/// harvest's total. The kind and the parcels stay as recorded, and the form
/// says so rather than showing fields that can't move.
struct ActivityCorrectionForm: View {
    @Binding var draft: ActivityCorrection.Draft
    let onNext: () -> Void
    let onCancel: () -> Void

    private var problems: [ActivityCorrection.Draft.Problem] { draft.problems() }

    var body: some View {
        PageForm {
            Section {
                ValueRow("Вид") { Text(draft.activity?.label ?? "—") }
                DatePicker("Дата", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                    .tint(Palette.DatePill.tint)
            } footer: {
                SectionFooter(Self.keptNote)
            }

            if draft.isHarvest {
                Section {
                    FieldRow("Количество", spoken: "Прибрано количество в килограми") {
                        TextField("кг", text: $draft.harvestText, prompt: .fieldPrompt("кг"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    SectionHeader("Прибрано, кг")
                } footer: {
                    SectionFooter(Self.harvestNote)
                }
            }

            Section {
                Text(problems.first?.text ?? Self.nextNote)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inlineTitle(TreatmentCorrectionFlow.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отказ", action: onCancel)
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Напред", action: onNext)
                    .disabled(!problems.isEmpty)
                    .accessibilityHint(problems.first?.text ?? "")
                    .accessibilityInputLabels(A11y.Spoken.next)
            }
        }
    }

    /// What isn't corrected here, and where it is: another kind is another
    /// record, and the parcels aren't correctable yet (agri-saas #2373).
    static let keptNote = "Видът и парцелите остават както са записани. "
        + "Друг вид работа се записва като нов запис, а грешен запис се изтрива от Дневник."
    /// «Нов запис»'s note, for parcels already recorded rather than chosen.
    static let harvestNote = "Общото прибрано количество от всички парцели на записа."
    private static let nextNote = "На следващата стъпка проверете промените, преди да ги запазите."
}
