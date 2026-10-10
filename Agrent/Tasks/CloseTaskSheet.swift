import SwiftUI

/// The green tick's form (#226): three questions, then the task is
/// complete — CLOSED on the wire, «Завършена» on screen (#236).
/// The rules live in `TaskCloseRules`; this draws them.
///
/// The sheet stays up until the close lands, and a refused close is said
/// inside it with every answer kept: the person filled in a form, and a
/// form that vanishes on a refusal reads as one that went through.
struct CloseTaskSheet: View {
    /// Whether question 2 is asked: the task has parcels to record the weeds
    /// on, or the app could not tell (then they go into the note only).
    let asksWeeds: Bool
    /// Closes the task; nil when it closed, the refusal to show otherwise.
    let submit: (TaskCloseAnswers) async -> String?
    let cancel: () -> Void

    @State private var answers = TaskCloseAnswers()
    @State private var sending = false
    @State private var refusal: String?

    private var tooLong: Bool { TaskCloseRules.isTooLong(answers, asksWeeds: asksWeeds) }
    private var ready: Bool { TaskCloseRules.isComplete(answers, asksWeeds: asksWeeds) && !tooLong }

    var body: some View {
        NavigationStack {
            PageForm {
                if let refusal {
                    Section {
                        Text(refusal)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(titled: "Задачата изпълнена ли е успешно?") {
                    ChoiceRow(title: "Да", chosen: answers.completed == true) { answers.completed = true }
                    ChoiceRow(title: "Не", chosen: answers.completed == false) { answers.completed = false }
                }

                if asksWeeds {
                    weeds
                }

                Section(titled: "Допълнителен коментар (по избор)") {
                    TextField("Коментар", text: $answers.comment,
                              prompt: .fieldPrompt("Напишете коментар…"), axis: .vertical)
                        .lineLimit(3...8)
                    if tooLong {
                        Text("Коментарът е твърде дълъг. Съкратете го.")
                            .font(.footnote)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // One word: between «Отказ» and the button a longer title was cut
            // to «Затваряне на з…» at the default size (A11yShots 08f).
            .inlineTitle("Завършване")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ", action: cancel)
                        .disabled(sending)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView() } else { Text("Завърши") }
                    }
                    .disabled(!ready || sending)
                    .accessibilityLabel("Завърши")
                    .accessibilityInputLabels(A11y.Spoken.complete)
                }
            }
            // A swipe down mid-send would leave a close in flight with no
            // form to report it in.
            .interactiveDismissDisabled(sending)
        }
    }

    /// Question 2: «Няма плевели», the catalogue by group, anything else.
    @ViewBuilder
    private var weeds: some View {
        Section(titled: "Какви плевели срещнахте?") {
            ChoiceRow(title: "Няма плевели", chosen: answers.noWeeds) {
                answers.noWeeds.toggle()
                // «None» and a weed cannot both be true.
                if answers.noWeeds {
                    answers.weeds = []
                    answers.otherWeeds = ""
                }
            }
        }
        // The web's group names (`weeds.groupGrass`, `weeds.groupBroadleaf`).
        weedGroup("Житен плевел", WeedCatalogue.binomials.filter(WeedCatalogue.grasses.contains))
        weedGroup("Широколистен плевел", WeedCatalogue.binomials.filter { !WeedCatalogue.grasses.contains($0) })
        Section(titled: "Друг плевел") {
            TextField("Друг плевел", text: $answers.otherWeeds,
                      prompt: .fieldPrompt("Името му; няколко — със запетая"), axis: .vertical)
                .promptRoom("Името му; няколко — със запетая")
                .onChange(of: answers.otherWeeds) { _, typed in
                    if !typed.trimmingCharacters(in: .whitespaces).isEmpty { answers.noWeeds = false }
                }
        }
    }

    private func weedGroup(_ title: String, _ keys: [String]) -> some View {
        Section(titled: title) {
            ForEach(keys, id: \.self) { key in
                ChoiceRow(title: WeedCatalogue.rowName(for: key), chosen: answers.weeds.contains(key)) {
                    if answers.weeds.remove(key) == nil {
                        answers.weeds.insert(key)
                        answers.noWeeds = false
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true
        refusal = await submit(answers)
        sending = false
    }
}
