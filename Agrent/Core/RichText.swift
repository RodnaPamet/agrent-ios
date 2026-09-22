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
/// 1. **No recognised tag means no tag pass**, so a note that is not markup is
///    never rewritten as though it were.
/// 2. **Only RECOGNISED tag names are stripped**, never `<[^>]*>`. The greedy
///    form is the trap: in `<p>температура < 5</p>` it matches from the bare
///    `<` to the `>` that closes `</p>` and silently swallows `5`. An unknown
///    tag therefore stays on screen — visible, reportable, and not a
///    disappeared measurement.
///
/// ── Entities always decode, even with no tag in sight ──
///
/// Measured server-side on 2026-09-22, against the real sanitiser rather than
/// the schema: the write path escapes before it stores, and it does so whether
/// or not there is any markup.
///
///     "температура < 5"          stored as  "температура &lt; 5"
///     "<p>температура < 5</p>"   stored as  "<p>температура &lt; 5</p>"
///     "5 > 3 & 2 < 4"            stored as  "5 &gt; 3 &amp; 2 &lt; 4"
///
/// The first row is the one that matters. It has NO tags, so an implementation
/// that gates the whole conversion on finding one returns it untouched and
/// puts a literal `&lt;` in front of the operator. Conservatism 1 therefore
/// gates the TAG pass only; decoding is unconditional. This is safe precisely
/// because the server always escapes: an author's literal ampersand is stored
/// as `&amp;amp;` and decodes back to `&amp;`, once.
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
        var s = html

        // ONLY the tag pass is gated on finding a tag. Entity decoding always
        // runs, and that distinction is load-bearing — see the measurement in
        // the type header. A note reading `температура < 5` is stored by the
        // server as `температура &lt; 5` with NO tags around it, so gating the
        // whole conversion would return it verbatim and put a literal `&lt;`
        // on screen.
        if anyKnownTag.firstMatch(
            in: s, range: NSRange(s.startIndex..., in: s)
        ) != nil {
            s = sub(lineBreak, in: s, with: "\n")
            s = sub(blockClose, in: s, with: "\n\n")
            s = sub(listItem, in: s, with: "\n• ")
            s = sub(anyKnownTag, in: s, with: "")
        }

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

    // MARK: - Writing

    /// Turn what an operator typed into the HTML this field actually holds.
    ///
    /// `notes` is a rich-text column on both ends — the web renders it through
    /// `dangerouslySetInnerHTML` and stores it through the same sanitiser, with
    /// TipTap as the reference producer. The app was POSTing PLAIN TEXT into
    /// it, which survives only because a string with no markup is valid HTML
    /// that happens to mean itself. It is the degenerate case, not the format.
    ///
    /// The visible consequence: HTML collapses whitespace, and the web renders
    /// this field with no `white-space: pre-line`. A two-paragraph note typed
    /// on the phone is stored faithfully and read as ONE run-on paragraph on
    /// the web. The same record, different on each screen.
    ///
    /// ── Why the phone escapes rather than letting the server do it ──
    ///
    /// Measured against the real sanitiser on 2026-09-22, both directions:
    ///
    ///     "<p>температура &lt; 5</p>"  unchanged, stable over 3 passes
    ///     "<p>температура < 5</p>"     becomes the escaped form, then stable
    ///
    /// So both encodings converge on the same stored bytes and neither is
    /// wrong. Escaping here is still the better dependency: the escaped form
    /// is a fixed point on the FIRST pass, so what the phone sends is what is
    /// stored rather than something the server decided; and the unescaped form
    /// is malformed markup that the server's parser recovers from. Recovery
    /// measured well — even `<5` with no space survived — but "sends valid
    /// markup" is a better guarantee for a client to make than "sends invalid
    /// markup the server is known to repair".
    ///
    /// Also measured: `&amp;amp;` survives three round trips as `&amp;amp;`.
    /// Escape levels do not accumulate on re-save, so this cannot slowly
    /// corrupt a register that other tools rewrite.
    ///
    /// A single-paragraph note produces exactly one `<p>`, so the ordinary
    /// case is unchanged by this.
    static func html(fromPlainText text: String) -> String? {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else { return nil }

        return paragraphs
            .map { paragraph in
                // A single newline inside a paragraph is a line break the
                // operator typed, not a paragraph boundary. HTML would eat it.
                let lines = paragraph
                    .components(separatedBy: "\n")
                    .map(escape)
                    .joined(separator: "<br>")
                return "<p>" + lines + "</p>"
            }
            .joined()
    }

    /// The three that change meaning in markup, ampersand FIRST.
    ///
    /// Order is the whole trick and getting it wrong is silent: escape `<`
    /// first and `&lt;` contains an `&` that the ampersand pass then turns
    /// into `&amp;lt;`, so the operator reads `&lt;` on both clients. One
    /// authored character, two escapes, and it looks like a server bug.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
