import SwiftUI

/// Creating a farm, on screen (agrent-ios#179). The rules are
/// `FarmWizardModel`'s; the words are the web wizard's, verbatim from
/// `messages/bg.json` (`farmWizard.*`), wherever it has the sentence.
///
/// Two ways in, one flow:
/// - ONBOARDING — `FarmGate`, for a person who belongs to no farm. The first
///   step also says that an invitation needs no new farm.
/// - ADDING — «Добави стопанство» on Профил, as a sheet.
/// Either way the new farm opens the moment it exists (owner, 2026-10-08).
struct FarmWizardView: View {
    enum Context { case onboarding, adding }

    let context: Context
    /// Opens the farm once it exists — `FarmStore.activate`.
    let open: (Farm) -> Void

    @State private var model = FarmWizardModel()
    @State private var eikText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FarmWizardText.stepOf(model.position.current, model.position.total))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.needsTerms {
                            Link(FarmWizardText.openTerms, destination: FarmWizardText.termsURL)
                        }
                    }
                    .font(.callout)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .pageBackground()
        .inlineTitle(context == .adding ? FarmWizardText.addTitle : FarmWizardText.newTitle)
        .toolbar {
            if context == .adding, model.step != .done {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
            }
        }
        // A sheet that is half-way through creating a REAL farm is not
        // swiped away by accident.
        .interactiveDismissDisabled(model.busy)
        .onChange(of: eikText) { _, text in model.setEik(text) }
        // The verdict appears under the field while the cursor is in it;
        // VoiceOver hears it rather than having to go and look.
        .onChange(of: model.eikState) { _, state in
            if let line = FarmWizardText.verdict(state) {
                AccessibilityNotification.Announcement(line).post()
            }
        }
    }

    private var title: String {
        switch model.step {
        case .type: FarmWizardText.typeTitle
        case .eik: FarmWizardText.eikTitle
        case .name: FarmWizardText.farmNameTitle
        case .done: FarmWizardText.doneTitle
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .type: typeStep
        case .eik: eikStep
        case .name: nameStep
        case .done: doneStep
        }
    }

    // MARK: - Steps

    /// No primary button: the two kinds ARE the choice, and promoting one
    /// would be the app choosing for the farmer (the web's reasoning).
    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            KindChoice(title: FarmWizardText.typeCompany, help: FarmWizardText.typeCompanyHelp,
                       icon: "building.columns") { model.choose(.company) }
            KindChoice(title: FarmWizardText.typeIndividual, help: FarmWizardText.typeIndividualHelp,
                       icon: "person") { model.choose(.individual) }
            if context == .onboarding {
                Text(FarmWizardText.invited)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var eikStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(FarmWizardText.eikLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                TextField(FarmWizardText.eikLabel, text: $eikText,
                          prompt: .fieldPrompt(FarmWizardText.eikPlaceholder))
                    .keyboardType(.numberPad)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .font(.title3.monospacedDigit())
                    .padding(12)
                    .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(FarmWizardText.eikLabel)
            }
            verdict
            actions(primary: FarmWizardText.eikYesMine, enabled: model.mayConfirmEik) {
                model.confirmEik()
            }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if case .checking = model.eikState {
            HStack(spacing: 8) {
                ProgressView()
                Text(FarmWizardText.eikChecking).foregroundStyle(Palette.secondaryText)
            }
            .font(.callout)
        } else if let line = FarmWizardText.verdict(model.eikState) {
            Text(line)
                .font(.callout)
                .foregroundStyle(FarmWizardText.isRefusal(model.eikState) ? Palette.error : Palette.success)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(FarmWizardText.farmNameLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                TextField(FarmWizardText.farmNameLabel, text: $model.name,
                          prompt: .fieldPrompt(FarmWizardText.farmNameLabel))
                    .textInputAutocapitalization(.words)
                    .padding(12)
                    .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 10))
                Text(FarmWizardText.farmNameHelp)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(primary: model.busy ? FarmWizardText.working : FarmWizardText.finish,
                    enabled: model.maySubmit) {
                Task { await model.submit() }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let farm = model.created?.farm {
                Text(farm.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(FarmWizardText.identityLine(model.created?.identityVerification))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let farm = model.farm else { return }
                open(farm)
                if context == .adding { dismiss() }
            } label: {
                Text(FarmWizardText.doneOpen).frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
        }
    }

    /// «Назад» beside the step's primary action — at the bottom, as on the
    /// web, rather than in a bar the sheet's «Отказ» already occupies.
    private func actions(primary: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        AdaptiveRow(spacing: 12) {
            Button(FarmWizardText.back) { model.back() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.busy)
            Button(action: action) {
                Text(primary).frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(!enabled)
        }
    }
}

/// One kind of farm, as a card the whole of which is the button.
private struct KindChoice: View {
    let title: String
    let help: String
    let icon: String
    let choose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: choose) {
            Group {
                if typeSize.isAccessibilitySize {
                    // STACKED at the accessibility sizes. Side by side, the
                    // icon outgrew its column and covered the title, and the
                    // words left over broke mid-way — «Стопан / ство с ЕИК»
                    // at AX5 (A11yShots, 2026-10-08). The icon and the way
                    // on share a row; the words get the card's full width.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            symbol
                            Spacer(minLength: 0)
                            chevron
                        }
                        words
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        symbol.frame(width: 28)
                        words
                        Spacer(minLength: 0)
                        chevron
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // One stop: what it is and what it means.
        .accessibilityElement(children: .combine)
        .accessibilityInputLabels(A11y.spokenNames(title))
    }

    private var symbol: some View {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(Palette.accent)
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(help).font(.subheadline).foregroundStyle(Palette.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.secondaryText)
            .accessibilityHidden(true)
    }
}

/// The words, in one place — the web's `farmWizard.*` verbatim, this app's
/// own where the web has no sentence.
enum FarmWizardText {
    /// The flag `POST /api/me/farms` follows; absent means off.
    static let flag = "social.farm-registration"

    static func stepOf(_ current: Int, _ total: Int) -> String { "Стъпка \(current) от \(total)" }
    static let back = "Назад"
    static let finish = "Готово"
    static let working = "Моля, изчакайте…"
    static let typeTitle = "Какво е стопанството Ви?"
    static let typeCompany = "Стопанство с ЕИК"
    static let typeCompanyHelp = "Юридическо лице, вписано в Търговския регистър."
    static let typeIndividual = "Земеделски стопанин — физическо лице"
    static let typeIndividualHelp = "Без ЕИК. Можете да добавите данни по-късно."
    static let eikTitle = "ЕИК на стопанството"
    static let eikLabel = "ЕИК"
    static let eikPlaceholder = "9 или 13 цифри"
    static let eikInvalid = "Това не е валиден ЕИК. Проверете цифрите."
    static let eikLooksLikeEgn = "Това прилича на ЕГН — не го въвеждайте тук."
    static let eikValidUnnamed = "Валиден ЕИК. Не можем да потвърдим името от регистъра."
    static func eikValidNamed(_ name: String) -> String { "Валиден ЕИК — \(name). Вашето ли е?" }
    static let eikYesMine = "Да, това е моето стопанство"
    static let eikChecking = "Проверяваме…"
    static let farmNameTitle = "Име на стопанството"
    static let farmNameLabel = "Име"
    static let farmNameHelp = "Така ще се нарича стопанството Ви в Agrent."
    static let doneTitle = "Стопанството Ви е онлайн"
    static let doneOpen = "Към стопанството"
    static let doneIdentityPending = "ЕИК-ът Ви е подаден за проверка. Ще го отбележим като потвърден, "
        + "след като наш служител го сравни с Търговския регистър."
    static let doneIdentityDeferred = "Стопанството е създадено, но ЕИК-ът не е записан. "
        + "Можете да го добавите в настройките."
    static let doneIdentityNone = "Можете да добавите ЕИК в настройките по всяко време."

    // This app's own.
    static let newTitle = "Ново стопанство"
    static let addTitle = "Добави стопанство"
    static let invited = "Поканени ли сте в съществуващо стопанство? Помолете собственика да Ви добави — "
        + "тогава няма нужда да създавате ново."
    static let openTerms = "Отвори условията за ползване"
    static let termsURL = Config.baseURL.appending(path: "accept-terms")

    /// The line under the ЕИК field, or nil for nothing to say yet.
    static func verdict(_ state: FarmWizardModel.EikState) -> String? {
        switch state {
        case .idle, .checking: nil
        case .valid(let name?): eikValidNamed(name)
        case .valid(nil): eikValidUnnamed
        case .invalid: eikInvalid
        case .looksLikeEgn: eikLooksLikeEgn
        case .failed(let message): message
        }
    }

    static func isRefusal(_ state: FarmWizardModel.EikState) -> Bool {
        if case .valid = state { return false }
        return true
    }

    /// Never says, or implies, that the ЕИК was ACCEPTED.
    static func identityLine(_ verification: FarmsAPI.IdentityVerification?) -> String {
        switch verification {
        case .pendingReview: doneIdentityPending
        case .deferred: doneIdentityDeferred
        case .notRequested, .unknown, nil: doneIdentityNone
        }
    }
}
