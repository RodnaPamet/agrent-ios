import Foundation

/// The text a farm agrees to before its page goes public (P6.6), and the
/// version the agreement is recorded against.
///
/// ── The web's text, word for word (owner, 2026-10-15) ──
///
/// The owner chose the web's wording and version for the phone rather than
/// a text of the phone's own. These are agri-saas `messages/bg.json`
/// `admin.publicProfile.consent*` and `CONSENT_TEXT_VERSION` in
/// `admin/public-profile/PublicProfileClient.tsx`, at 7c1904dfb (#2257). v2 is
/// the owner's review of v1: it adds the paragraph saying the address itself
/// is public and ends up printed.
///
/// ── Edited at v2, on purpose (agri-saas #2257, 2026-10-24) ──
///
/// ЕГН left the "НЕ се публикуват" sentence when the product stopped holding
/// it (owner, 2026-10-24). The web kept the version at v2: a new one blocks
/// every published farm until it agrees again, and nothing that becomes
/// PUBLIC changed — that is the test for a bump, not whether characters did.
/// So the phone copies the text and keeps v2 too.
///
/// ── The version is what makes the record mean something ──
///
/// `PUT /farm-brand/consent` stores `textVersion` beside the time, so "they
/// agreed" can be held against one wording. The server takes whatever
/// version it's sent, so the phone must only ever send the version of the
/// text it showed. That's why the body is pinned by a hash in the tests: a
/// word changed here without a new version would record agreement to a text
/// nobody was shown under that name.
///
/// When the web moves to v3, this file follows: the new text and version,
/// copied together. Until it does, the phone keeps asking for v2 and records
/// v2, which stays true of what the person read. The web will ask that farm
/// again, because it re-asks whenever the recorded version isn't its own.
enum PublishingConsent {
    static let version = "v2"

    static let heading = "Съгласие за публикуване"
    static let intro = "Прочетете и потвърдете, преди страницата да стане публична."
    static let body = """
        Публикуването прави страницата на стопанството достъпна за всеки в интернет, без профил и без вход.

        Публично се виждат: публичното име, краткото описание, текстът «За стопанството», областта и културите. НЕ се публикуват ЕИК, адрес, община или населено място — тези данни остават само във Вашия профил.

        Публичният адрес, който избирате — например app.agrent.bg/f/pobeda — също е публичен и е самата връзка към страницата. Изберете го внимателно: той се отпечатва върху материали и се препраща в съобщения, които след това не можете да редактирате.

        Връзката може да бъде препратена и отворена от всеки, който я получи.

        Индексирането от търсачки е отделно решение и е изключено по подразбиране. Можете да го включите по-късно.

        Можете да оттеглите публикуването по всяко време и страницата спира да отговаря веднага. Вече споделени връзки и отпечатани материали обаче остават такива, каквито са — оттеглянето не ги връща обратно.
        """
    static let agree = "Прочетох и съм съгласен/на страницата да бъде публикувана."
    static let confirm = "Съгласявам се и публикувам"
    /// Said above the text when the farm agreed to an older one.
    static let stale = "Текстът за съгласие е обновен, откакто го потвърдихте. Прочетете го отново, преди страницата да стане публична."

    /// The recorded agreement covers the text this build shows. A time with
    /// another version, or none, is an agreement to something else.
    static func isCurrent(_ draft: FarmBrandDraft?) -> Bool {
        draft?.consentedAt != nil && draft?.consentTextVersion == version
    }

    /// The farm agreed once, to a text this build no longer shows.
    static func isStale(_ draft: FarmBrandDraft?) -> Bool {
        draft?.consentedAt != nil && !isCurrent(draft)
    }

    /// «Съгласието е записано на 1 октомври 2026 г.»: the web's sentence,
    /// with the year's «г.» as its full stop.
    static func recorded(_ date: Date) -> String {
        "Съгласието е записано на " + BgDate.fullEndingSentence(date)
    }
}
