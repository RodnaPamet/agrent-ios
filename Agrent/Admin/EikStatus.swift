import SwiftUI

/// What the farm-profile page and its editor SAY about the ЕИК's
/// verification (agri-saas#1355), as a pure value so the copy, the colour
/// role and the spoken sentence are unit tests rather than screenshots.
///
/// ── THE WORDING ──
///
/// agri-saas `messages/bg.json` has no wording for any of the four states —
/// #1355 shipped the field and the staff console, no farmer-facing UI — so
/// the copy is written here and the web should take it from here, not the
/// other way round. Each line is what the spec's description of the enum
/// says the farmer should be told:
///
///   NONE      «Непроверен»             a number shown predates verification
///   PENDING   «В процес на проверка»   nothing wrong, nothing confirmed
///   VERIFIED  «Проверен» + a tick      the only state where `eik` is authoritative
///   DISPUTED  «Не съвпада със съществуващ запис — свържете се с екипа на Agrent.»
///
/// ── DISPUTED IS NOT AN ACCUSATION ──
///
/// The spec says so in bold, and the reason is factual rather than polite:
/// the state means only that the claim collided with an existing verified
/// claim on the same number, which a mistyped digit produces as readily as
/// anything else. So the line states the fact (no match), gives the one way
/// forward (the Agrent team) and says nothing about the farmer. No
/// «оспорен», no «невалиден», no «отхвърлен» — `EikStatusTests` holds the
/// line against a list of such words. The colour is `warning`, not `error`,
/// for the same reason: it is a caveat to act on, not a failure.
///
/// ── WHEN NOTHING IS SHOWN ──
///
/// `.unknown` — an older server, a value this build does not know — shows
/// nothing at all: the safe reading of "no information" is to say nothing,
/// not to guess. NONE with no number also shows nothing: there is nothing
/// to be unverified, and «Непроверен» under a dash would read as a fault.
struct EikStatus: Equatable, Sendable {
    /// The colour ROLE, mapped to `Palette` by the view. Kept out of SwiftUI
    /// so the mapping is testable as an equality.
    enum Tone: Equatable, Sendable {
        case success, neutral, warning
    }

    let text: String
    let tone: Tone
    /// SF Symbol drawn before the text, or nil for none. Colour is never the
    /// only signal: every state has its words.
    let symbol: String?

    /// THE COPY, one line per wire state. nil for `.unknown`.
    static func text(for state: EikVerification) -> String? {
        switch state {
        case .unclaimed: "Непроверен"
        case .pending: "В процес на проверка"
        case .verified: "Проверен"
        case .disputed: "Не съвпада със съществуващ запис — свържете се с екипа на Agrent."
        case .unknown: nil
        }
    }

    /// What to show beside an ЕИК, or nil for nothing.
    ///
    /// `hasNumber`: whether the profile holds an ЕИК to show. PENDING and
    /// DISPUTED are shown WITHOUT one — and usually are without one, because
    /// the server writes `eik` only at verification (the claim itself keeps
    /// a blind index, never the number), so a farm waiting on a review has a
    /// null `eik` and still needs to hear that the review is under way.
    static func of(_ state: EikVerification, hasNumber: Bool) -> EikStatus? {
        guard let text = text(for: state) else { return nil }
        switch state {
        case .unclaimed:
            return hasNumber ? EikStatus(text: text, tone: .neutral, symbol: nil) : nil
        case .pending:
            return EikStatus(text: text, tone: .neutral, symbol: "clock")
        case .verified:
            return EikStatus(text: text, tone: .success, symbol: "checkmark.seal.fill")
        case .disputed:
            return EikStatus(text: text, tone: .warning, symbol: "info.circle")
        case .unknown:
            return nil
        }
    }

    /// Whether the profile page should draw an ЕИК row at all.
    ///
    /// The page hides an empty field (`FarmProfileView.field`), and an empty
    /// ЕИК with nothing to say about it stays hidden. But an empty ЕИК WITH a
    /// status is a row: «В процес на проверка» is news about the ЕИК even
    /// before there is a number to print.
    static func showsRow(eik: String?, state: EikVerification) -> Bool {
        hasNumber(eik) || of(state, hasNumber: false) != nil
    }

    static func hasNumber(_ eik: String?) -> Bool {
        !(eik ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The ЕИК row as ONE spoken sentence: the label, the number and the
    /// status, so a VoiceOver user hears the number and what is known about
    /// it together rather than as three stops.
    ///
    /// THE DIGITS ARE SPOKEN ONE BY ONE. Unspaced, «203912345» is read as
    /// «двеста и три милиона…», which is not how anyone reads an identifier
    /// back to a clerk. Only an all-digit value is spaced; anything else is
    /// passed through as stored.
    ///
    /// Not a national ID: the owner's ruling is that ЕИК is a business
    /// identifier on public filings, so unlike the ЕГН it is spoken.
    static func spoken(eik: String?, state: EikVerification) -> String {
        let number = (eik ?? "").trimmingCharacters(in: .whitespaces)
        let said: String
        if number.isEmpty {
            said = "ЕИК, не е попълнено"
        } else if number.allSatisfy(\.isASCIIDigitCharacter) {
            said = "ЕИК " + number.map(String.init).joined(separator: " ")
        } else {
            said = "ЕИК " + number
        }
        return A11y.sentence([said, of(state, hasNumber: !number.isEmpty)?.text])
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}

/// The status line under the ЕИК, shared by the page and the editor so the
/// two cannot disagree.
///
/// Draws nothing for a nil status. Not an accessibility element of its own:
/// the row it sits in speaks it as part of `EikStatus.spoken`.
struct EikStatusLine: View {
    let status: EikStatus?

    var body: some View {
        if let status {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(status.text)
                    // Wraps at every Dynamic Type size; the DISPUTED line is
                    // a full sentence and must never be truncated mid-way.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(Self.colour(status.tone))
        }
    }

    /// The tone's `Palette` role. Every one is measured in all three themes
    /// on both surfaces it sits on — `Surface.page` (the profile page) and
    /// `Surface.card` (the editor) — in `PaletteTokenTests`.
    static func colour(_ tone: EikStatus.Tone) -> Color {
        switch tone {
        case .success: Palette.success
        case .neutral: Palette.secondaryText
        case .warning: Palette.warning
        }
    }
}
