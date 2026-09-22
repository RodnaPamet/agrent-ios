import Foundation

/// A calculator refusal, in Bulgarian, with its values filled in.
///
/// ── The rule, which is the web's ──
///
///     if (isKnownRefusalCode(code)) return translate(`refusal.${code}`, params)
///     return fallbackEnglish
///
/// Translate a code we recognise; fall back to the server's own English
/// sentence for one we do not. An unknown future code must still say
/// something rather than nothing.
///
/// ── AND ONE PLACE THIS DELIBERATELY DIVERGES FROM THE WEB ──
///
/// `{commodity}` is a CANONICAL SLUG — `wheat`, not `Пшеница`. The web
/// passes params straight to its translator with no lookup, so it currently
/// renders:
///
///     Няма налична пазарна цена за wheat.
///
/// A Bulgarian sentence with an English slug inside it: the identical
/// defect the owner reported this morning, one layer further in, sitting
/// behind a branch this tenant has not hit. The web is the reference for
/// WORDING and it is wrong about this particular substitution, so the
/// wording is taken and the substitution is not.
///
/// `commodity` therefore goes through `CommodityName.canonical`, which also
/// gives it the title-cased fallback for a slug in no catalogue. Currency
/// codes are substituted as-is: `BGN` and `EUR` are ISO codes and are the
/// same in both languages.
enum RefusalText {

    /// Only these keys are substituted. A `{…}` this does not know is left
    /// exactly as written rather than blanked — a sentence with a visible
    /// `{foo}` is reportable, and one silently missing a clause is not.
    static func resolve(code: String?, params: [String: String]?, fallback: String?) -> String? {
        guard let code, let template = UserMessage.bulgarian[code] else {
            return fallback
        }
        guard let params, !params.isEmpty else { return template }

        var out = template
        for (key, value) in params {
            let display: String
            switch key {
            case "commodity":
                // The slug, translated. See the divergence note above.
                display = CommodityName.canonical(value) ?? value
            default:
                display = value
            }
            out = out.replacingOccurrences(of: "{\(key)}", with: display)
        }
        return out
    }
}
