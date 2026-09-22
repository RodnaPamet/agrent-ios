import Foundation

/// Server `notes` are HTML. This renders them as text a person can read.
///
/// ── The defect ──
///
/// Measured on the device, 2026-09-22, against the live tenant payload: of the
/// entries carrying `notes`, **2 of 2 contain HTML** — not an outlier, the
/// format. `JournalDetailView` handed the string straight to a SwiftUI `Text`,
/// so the operator read
///
///     <p>Sample input-application record.</p>
///
/// tags and all. It surfaced only now because until that screen shipped, the
/// `notes` field was not displayed ANYWHERE in the app — the list renders
/// title, type, date and status and never touches it. The first screen to show
/// a field is the first chance to discover what the field actually contains.
///
/// ── Why not `NSAttributedString(data:options:.html)` ──
///
/// Foundation's HTML importer is WebKit-backed: it must run on the main thread,
/// it is slow enough to be visible while scrolling, and it drags a full parse
/// of a document off one paragraph of text. This screen needs paragraph breaks
/// and readable punctuation, which is a fraction of that at none of the cost,
/// and it works with no signal and no WebKit warm-up.
///
/// ── The rule this follows: never eat the operator's words ──
///
/// Two deliberate conservatisms, both chosen because losing text an operator
/// wrote is worse than leaving a stray tag on screen:
///
/// 1. **A string with no recognised tag is returned VERBATIM.** A note reading
///    `температура < 5°C` is not HTML and must not be treated as though it
///    were.
/// 2. **Only RECOGNISED tag names are stripped**, never `<[^>]*>`. The greedy
///    form is the trap: in `<p>температура < 5</p>` it matches from the bare
///    `<` to the `>` that closes `</p>` and silently swallows `5`. An unknown
///    tag therefore stays on screen — visible, reportable, and not a
///    disappeared measurement.
enum RichText {

    /// Tag names the server's editor can emit. Anything outside this list is
    /// left on screen on purpose; see conservatism 2 above.
    private static let names = [
        "p", "br", "div", "span", "ul", "ol", "li", "h[1-6]",
        "strong", "b", "em", "i", "u", "s", "a", "blockquote", "pre", "code",
        "table", "thead", "tbody", "tr", "td", "th", "hr",
        "small", "sub", "sup", "mark", "figure", "figcaption",
    ].joined(separator: "|")

    /// Force-unwrapped because every pattern here is a compile-time constant
    /// literal — it either compiles on the first run or on none, so a failure
    /// is a build-time typo rather than anything a payload can cause.
    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let anyKnownTag = re("</?(?:\(names))\\b[^>]*>")
    private static let lineBreak   = re("<(?:br|hr)\\b[^>]*>")
    private static let blockClose  = re("</(?:p|div|li|h[1-6]|blockquote|tr|pre)\\s*>")
    private static let listItem    = re("<li\\b[^>]*>")
    private static let entity      = re("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});")
    private static let blankRun    = re("\n{3,}")

    static func plainText(_ html: String) -> String {
        guard anyKnownTag.firstMatch(
            in: html, range: NSRange(html.startIndex..., in: html)
        ) != nil else { return html }

        var s = html
        s = sub(lineBreak, in: s, with: "\n")
        s = sub(blockClose, in: s, with: "\n\n")
        s = sub(listItem, in: s, with: "\n• ")
        s = sub(anyKnownTag, in: s, with: "")
        s = decodeEntities(s)
        s = sub(blankRun, in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sub(
        _ regex: NSRegularExpression, in s: String, with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template
        )
    }

    /// Entities are decoded ONCE, after tags are stripped, and in a single
    /// left-to-right pass.
    ///
    /// Both parts matter. Decoding before stripping would turn an author's
    /// literal `&lt;p&gt;` into a `<p>` and then delete it — the one case where
    /// the operator really did type a tag. And decoding `&amp;` in its own
    /// pass, as a chain of `replacingOccurrences` would, turns `&amp;lt;` into
    /// `&lt;` and then into `<` on the next pass: one authored ampersand, two
    /// decodes, wrong answer.
    private static func decodeEntities(_ s: String) -> String {
        let ns = s as NSString
        let matches = entity.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let body = ns.substring(with: m.range(at: 1))
            // An entity this does not know stays EXACTLY as written. Dropping
            // it would lose a character the operator can currently at least
            // see and report.
            out += replacement(for: body) ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func replacement(for body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[body.lowercased()]
    }

    /// `&nbsp;` becomes an ORDINARY space, not U+00A0.
    ///
    /// A non-breaking space is the author's layout intent on a desktop page and
    /// a hazard here: it forbids a wrap at exactly the point Dynamic Type at
    /// `accessibility3` most needs one, which is the overflow this app has
    /// already been bitten by twice. On a 390pt screen, readable beats faithful.
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·", "bull": "•",
        // Bulgarian typography uses „…“ where English uses “…”, and the web
        // editor emits whichever the author pressed. Both, plus the guillemets.
        "bdquo": "„", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "laquo": "«", "raquo": "»",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½",
        "sup2": "²", "sup3": "³", "micro": "µ", "permil": "‰",
        "euro": "€", "copy": "©", "reg": "®", "trade": "™",
    ]
}
