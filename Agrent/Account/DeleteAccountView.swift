import SwiftUI

/// «Изтриване на профила» — what deleting the account does, then the request
/// (agrent-ios#281; App Store guideline 5.1.1(v)).
///
/// ── Says no more than the privacy notice ──
///
/// The paragraphs are the web's own (`privacy.deleteRequest`,
/// `deleteWhatHappens`, `deleteIncomplete` in agri-saas `messages/bg.json`),
/// cut to a phone's length and never widened: erasure is INCOMPLETE by design
/// (GDPR Art 17(3)(b)), and a page that promised more would be the one place
/// the app and the notice disagreed. The whole notice is one link away.
///
/// ── No number of days before the request ──
///
/// The grace period comes from the server (`DELETION_GRACE_DAYS`) and is not
/// written here. The page says there IS time to change one's mind; the date
/// itself is said on the sign-in screen once the server has set it
/// (`AuthClient.accountDeletionRequested`).
///
/// ── One question first ──
///
/// Like Изход, a confirmation before anything is sent. Not more than that:
/// the grace period is what protects against a mistake, and App Review
/// expects deletion to be easy to reach and to finish.
struct DeleteAccountView: View {
    @Environment(AuthClient.self) private var auth
    @State private var confirming = false
    @State private var failure: String?

    private typealias Words = AccountDeletionText

    var body: some View {
        List {
            Section {
                ForEach(Words.explanation, id: \.self) { paragraph in
                    Text(paragraph).fixedSize(horizontal: false, vertical: true)
                }
                Link(Words.privacyLink, destination: Config.baseURL.appending(path: "/privacy"))
                    .accessibilityInputLabels(A11y.spokenNames(Words.privacyLink, "Privacy policy"))
            }
            .pageRow()

            Section {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    if auth.requestingDeletion {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Words.deleting)
                    } else {
                        Label(Words.action, systemImage: "trash")
                            .foregroundStyle(Palette.destructive)
                    }
                }
                .disabled(auth.requestingDeletion)
                .accessibilityInputLabels(A11y.Spoken.deleteAccount)
                // On the row that asks: the dialog animates from its trigger.
                .confirmationDialog(Words.confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                    Button(Words.action, role: .destructive) {
                        Task { await delete() }
                    }
                    .accessibilityInputLabels(A11y.Spoken.deleteAccount)
                    Button("Отказ", role: .cancel) {}
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                } message: {
                    Text(Words.confirmMessage)
                }
            } footer: {
                SectionFooter {
                    if let failure {
                        Text(failure).foregroundStyle(Palette.error)
                    }
                }
            }
            .pageRow()
        }
        .pageBackground()
        .inlineTitle(Words.title)
        .onChange(of: failure) { _, failure in
            guard let failure else { return }
            var line = AttributedString(failure)
            line.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(line).post()
        }
    }

    /// Sent once, by `AuthClient`. If it landed, this phone's session is
    /// gone with every other and the app goes to the sign-in screen; if it
    /// did not, the person can ask again — the server does not restart the
    /// clock for a second request.
    private func delete() async {
        failure = nil
        do {
            try await auth.requestAccountDeletion()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// The words of account deletion, here and on the recovery screen.
enum AccountDeletionText {
    static let title = "Изтриване на профила"
    static let action = "Изтрий профила"
    static let deleting = "Изтриване"
    static let privacyLink = "Политика за поверителност"

    /// The privacy notice's three paragraphs, in a phone's length.
    static let explanation = [
        "Ще бъдете отписани от всички устройства, а профилът Ви ще престане да се вижда "
            + "от други стопанства веднага.",
        "Нищо не се премахва веднага. Ако промените решението си, влезте отново и изберете "
            + "«Възстанови профила». Срокът е за Ваша защита — срещу прибързано решение или срещу "
            + "използване на профила Ви от друг.",
        "След срока името Ви се изтрива, а имейл адресът Ви се заменя, така че можете да се "
            + "регистрирате отново с него. Данните Ви за вход се изтриват напълно. Обявите, "
            + "разговорите и съобщенията остават, като името Ви се заменя със случаен код — те "
            + "принадлежат и на другата страна.",
        "Не можем да изтрием всичко: сигнал за съдържание, който сте подали, остава свързан "
            + "с Вас, защото законът ни задължава да пазим запис за него.",
    ]

    static let confirmTitle = "Изтриване на профила?"
    static let confirmMessage = "Ще бъдете отписани от всички устройства. Докато срокът тече, "
        + "можете да влезете отново и да възстановите профила."

    // ── The recovery screen (`DeletionPendingView`) ──

    static let pendingTitle = "Профилът Ви е заявен за изтриване"
    static let restore = "Възстанови профила"
    static let restoring = "Възстановяване"

    /// The server's date, and what restoring does — including what it does
    /// not: the sessions the request ended stay ended.
    static func pending(erasesAt: Date?) -> String {
        let when = erasesAt.map { "Ще бъде изтрит на \(BgDate.full($0)). Дотогава можете да го възстановите." }
            ?? "Докато не бъде изтрит, можете да го възстановите."
        return when + " Ако го възстановите, на другите си устройства ще трябва да влезете отново."
    }

    /// When the request's answer was lost and the session turned out to be
    /// revoked: likely recorded, not known. Signing in shows which — the
    /// recovery screen if it was.
    static let sessionEnded = "Сесията Ви е прекратена и заявката за изтриване вероятно е приета. "
        + "Влезте отново, за да видите състоянието на профила."

    /// On the sign-in screen once the request is recorded: the server's date,
    /// never one computed here, and how to undo it.
    static func requested(erasesAt: Date?) -> String {
        guard let erasesAt else {
            return "Профилът Ви ще бъде изтрит. Докато срокът тече, можете да влезете отново "
                + "и да го възстановите."
        }
        return "Профилът Ви ще бъде изтрит на \(BgDate.full(erasesAt)). Дотогава можете да влезете "
            + "отново и да го възстановите."
    }
}
