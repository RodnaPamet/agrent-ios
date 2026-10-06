import SwiftUI

/// The app's colour, by ROLE — and since P2.8 (agri-saas#1193) every role's
/// value comes from the design tokens rather than from a literal here.
///
/// WHERE THE VALUES LIVE. agri-saas `design/tokens.json` generates both the
/// web CSS and `Tokens.swift`; `scripts/sync-design-tokens.sh` vendors the
/// latter into `Design/Generated/` and a hash check fails on any hand edit.
/// So a colour change is made ONCE, in tokens.json, and reaches both
/// platforms — the web and this app had been choosing their palettes
/// separately, and the ochre, the green-black page and the systemGreen below
/// were three places where they had drifted apart. This file chooses WHICH
/// token answers each role; it never chooses a hex value.
///
/// WHICH THEME. The tokens have three arms: dark, light and highContrast,
/// the web's «Слънце». On the web «Слънце» is an explicit theme the user
/// picks, and it is the LIGHT palette plus a contrast overlay (agri-saas
/// `attributesFor('sunlight')` sets `data-theme="light"` AND
/// `data-contrast="high"`; the generator resolves highContrast through light
/// for that reason). iOS has no theme picker, so the system settings choose:
///
///     Dark appearance                      -> dark
///     Light appearance                     -> light
///     Light appearance + Increase Contrast -> highContrast («Слънце»)
///     Dark appearance + Increase Contrast  -> dark
///
/// The last row is the decision. «Слънце» is a white page with black ink, so
/// handing it to someone in dark mode would flip a whole dark interface —
/// system bars, sheets, keyboards — to a white app inside it. There is no
/// dark high-contrast arm to give them instead, and the dark arm already
/// passes 4.5:1 for every text role below, most of them above 7:1 (the
/// lowest is `accentDeep` at 5.11). Increase Contrast in
/// dark mode still does what it did before this change: the parcel map's
/// near-solid fills (`Map.fillOpacity(_:)`) and the per-view strokes that
/// read `colorSchemeContrast` themselves.
///
/// WHY THE ACCENT IS GOLD AND NOT GREEN, which is the load-bearing decision
/// and survives the move to tokens: green on the parcel map is DATA — it
/// encodes whether a parcel is sown. An app accent in the same family would
/// read as one more state, so the accent is the brand gold, a colour the map
/// never uses. Before the tokens the LIGHT accent was a canvas ochre
/// (#A04E1B); the web's light rebrand (P2.4) made it a deep goldenrod and
/// this app now follows it.
///
/// EVERY RATIO BELOW is WCAG 2.x, measured on the token values with
/// translucent fills composited over `Surface.page`, and `PaletteTokenTests`
/// recomputes each from the colours as the app resolves them — a comment can
/// go stale, a test of the resolved colour cannot. Columns are
/// dark / light / «Слънце».
///
/// Map colours are NOT tokens: they are data encodings tuned for sunlight
/// over a schematic ground, and the web has no parcel map to share them with.
enum Palette {
    /// Tabs, buttons, links, and the fill of the floating action button.
    /// `--brand-default`.
    ///
    ///     on Surface.page    7.91   4.90   5.49
    ///
    /// Light is the tightest pair in this file that still passes; it is the
    /// web's own measured link colour on the same cream page.
    static let accent = Color(token: AgrentColor.brandDefault)

    /// Pressed, and the stronger brand ink. `--brand-emphasis`.
    ///
    ///     on Surface.page    5.11   5.82   6.51
    static let accentDeep = Color(token: AgrentColor.brandEmphasis)

    /// WHAT TO WRITE ON TOP OF `accent`. Never `.white` directly.
    /// `--content-inverted`, which is what the web's primary button writes
    /// on its brand fill.
    ///
    /// The reason this exists is unchanged: the dark accent is gold and gold
    /// is bright, so white on it measured 2.10:1. Three sites once wrote
    /// `.foregroundStyle(.white)` over an accent fill — the floating action
    /// button, the map's index chips and the exchange map's region fills —
    /// and a farmer was reading white on gold outdoors. A pair defined
    /// together cannot drift apart, and the next accent-filled control gets
    /// it for free.
    ///
    ///     on accent          8.45   5.21   5.21
    ///     on accentDeep      5.46   6.19   6.19
    static let onAccent = Color(token: AgrentColor.contentInverted)

    /// The page: every scrolling screen, and every List row through
    /// `pageRow()`. `--bg-page`.
    ///
    /// ONE COLOUR, not a page/card pair, and that part is deliberate history.
    /// The first dark theme had a page under lighter cards, and getting that
    /// right meant touching every list in the app — three of seven were
    /// reached, so three screens had green rows and four still had black
    /// ones. A single value is much harder to get half-right: every surface
    /// takes the same colour, and a screen that is missed is obviously wrong
    /// rather than subtly inconsistent.
    ///
    /// LIGHT CHANGES with this: it was `systemBackground` (white) and is now
    /// the web's warm off-white, #F4F2ED; «Слънце» is pure white.
    ///
    /// SOLID, ALL OF IT (P2.8 "solid surfaces"). DESIGN.md's first exception
    /// to Apple's defaults: translucency spends a contrast budget a farmer in
    /// direct sun does not have, and a material takes its colour from
    /// whatever scrolls under it — over the satellite map, that is a
    /// different colour for every field. So every surface that carries text
    /// is one of the opaque tokens below. The navigation bar is `page` (see
    /// `SolidChrome`), so a large title sits on the same colour as the list
    /// it heads.
    ///
    /// Every ratio on `bar` / `card` is in `PaletteTokenTests`, all three
    /// arms. «Слънце» has `--bg-default` equal to the page (both white), so
    /// there the separation is carried by `edge` alone — which is #8A8A8A in
    /// that arm, the strongest of the three, as it should be.
    enum Surface {
        static let page = Color(token: AgrentColor.bgPage)

        /// A band pinned to an edge of the screen: the tab bar, the bottom
        /// action bars («Нов запис», «Нов разход»), the composer, the outbox
        /// banner, the map's index controls and its target button.
        /// `--bg-default`, which is exactly what the web's bottom tab bar
        /// (`BottomTabBar.tsx`) is painted with.
        ///
        ///     accent             6.59   5.09   5.49
        ///     secondaryText      7.64   7.24  11.37
        ///     warning            8.30   6.48   7.13
        ///     error              6.05   7.85   7.75
        ///     success            8.54   6.83   8.08
        ///     primary           13.85  19.47  21.00
        ///
        /// NOT `accentDeep`: 4.26 in dark, below 4.5. Nothing writes it on a
        /// bar today, and a test pins the shortfall so it stays visible.
        static let bar = Color(token: AgrentColor.bgDefault)

        /// A grouped block on the page — the parcel list under the map, a
        /// Тенденции chart card. The web's card is the same token as its
        /// bar, so this is a second NAME for one value: a role that may
        /// diverge later, not a second colour today.
        static let card = Color(token: AgrentColor.bgDefault)

        /// The hairline between a bar and what scrolls past it.
        /// `--border-subtle`, the web bottom bar's `border-t`. Decorative —
        /// it is not the only thing separating the two, so it carries no
        /// 3:1 obligation.
        static let edge = Color(token: AgrentColor.borderSubtle)
    }

    /// The ONLY colour that means "something is broken". Reserved: staleness,
    /// refusals and withheld data are not errors and must not borrow it.
    /// `--content-error`.
    ///
    /// It is the colour every failure message in the app is written in — a
    /// failed cost save, a refused operation, a listing that would not post —
    /// so it is the message a farmer most needs to read. The pre-token dark
    /// value had to be lightened for exactly that reason (#B4472A measured
    /// 3.39:1 on the dark page); the token is already light in dark.
    ///
    ///     on Surface.page    7.26   7.57   7.75
    static let error = Color(token: AgrentColor.contentError)

    /// WHAT TO WRITE ON TOP OF `error` when it is the FILL rather than the
    /// ink — the same pairing `onAccent` makes, for the same reason: the dark
    /// error is light precisely so it can be READ on a dark page, which
    /// makes it a poor thing to put white on. `--content-inverted`.
    ///
    ///     on error           7.76   8.05   7.37
    static let onError = Color(token: AgrentColor.contentInverted)

    /// The counterpart: something WORKED. Reserved the same way `error` is.
    /// `--content-success`.
    ///
    /// `Color.green` once stood in for this at three sites, and systemGreen
    /// on white is 2.22:1 — «Запитването е изпратено.», the one sentence
    /// confirming an inquiry reached a buyer, was printed at that.
    ///
    /// This does not contradict the header's rule about green. That rule is
    /// about the ACCENT; a success tick is not on the map and is not the
    /// accent.
    ///
    ///     on Surface.page   10.25   6.59   8.08
    static let success = Color(token: AgrentColor.contentSuccess)

    /// NOT BROKEN, BUT NOT RIGHT EITHER — the caveat colour.
    /// `--content-warning`.
    ///
    /// What it marks, everywhere: a satellite reading older than a pass, an
    /// outbox entry the server refused, a break-even that is not covered, a
    /// product with no ЗЗР number, a file that will duplicate every parcel if
    /// it has already been imported. None of those is an error and none is
    /// decoration — they are the sentence a farmer must read before acting,
    /// which is why fourteen sites of `Color.orange` (2.20:1 on white) were
    /// replaced by this.
    ///
    ///     on Surface.page    9.96   6.24   7.13
    static let warning = Color(token: AgrentColor.contentWarning)

    /// SECONDARY TEXT, at 109 sites. `--content-muted`.
    ///
    /// `Color.secondary` is `secondaryLabel`, #3C3C43 at 60%, and over a
    /// white row it composites to 3.44:1 — Apple's own value behaving as
    /// documented, and below the 4.5:1 body text needs. A literal (now a
    /// token) also fixes what opacity could not: a translucent grey takes its
    /// final colour from whatever is behind it, which is how a chip's label
    /// once ended up at 3.19:1 over a fill nobody had measured it against.
    ///
    /// Secondary text has a job — being visibly subordinate to primary — and
    /// the tokens keep that separation: primary (`--content-emphasis`) is
    /// 16.63 / 15.56 / 21.00 on the page.
    ///
    ///     on Surface.page    9.17   6.98  11.37
    static let secondaryText = Color(token: AgrentColor.contentMuted)

    /// Entry-type chips. Two families so a glance separates an input
    /// application from an observation without reading, plus a neutral one.
    /// The pairs follow the web's `Badge` variants (agri-saas
    /// `src/components/ui/badge.tsx`), with one exception that is the
    /// input text.
    ///
    /// Ratios are text on its own fill, the fill composited over the page —
    /// a chip's text is `.caption`, normal-size text, so 4.5:1 applies:
    ///
    ///     input              7.33   5.29   5.83
    ///     activity           6.53   6.79   7.43
    ///     neutral            7.48   6.51  10.43
    ///
    /// THE INPUT TEXT IS TWO TOKENS. The web's `brand` badge writes
    /// `--brand-muted` on `--brand-subtle`, which passes in dark (7.33) and
    /// measures 1.71 in light and 1.88 in «Слънце». The tokens' own note
    /// names `--brand-emphasis` as the text for brand-subtle tiles, which
    /// passes in light and «Слънце» but measures 3.80 in dark. No single
    /// brand token passes on that fill in all three arms, so dark takes the
    /// badge's token and light/«Слънце» take the note's — both are pairings
    /// the web itself declares, and no value is invented. Filed as
    /// agri-saas#1331; when tokens.json gains one token that passes on the
    /// tint everywhere, this becomes a plain `Color(token:)`.
    enum Chip {
        static let inputText = Color(token: { theme in
            theme == .dark ? AgrentColor.brandMuted(theme) : AgrentColor.brandEmphasis(theme)
        })
        static let inputFill = Color(token: AgrentColor.brandSubtle)
        static let activityText = Color(token: AgrentColor.contentInfo)
        static let activityFill = Color(token: AgrentColor.bgInfo)
        /// Two tokens chosen as a pair. Before the tokens this was
        /// `secondaryLabel` over `secondarySystemFill`, two system colours
        /// that drifted against each other to 3.19:1 in light — a grey at 60%
        /// over a grey at 16%. The web's neutral badge is exactly this pair.
        static let neutralText = Color(token: AgrentColor.contentMuted)
        static let neutralFill = Color(token: AgrentColor.bgSubtle)
    }

    /// The three speakers of an exchange conversation (agri-saas #1323): me,
    /// a colleague at my farm, and the other side. Each is a FILL and the INK
    /// written on it, chosen as pairs so that the three are told apart by
    /// more than hue:
    ///
    ///     me           solid gold     `accent` under `onAccent`
    ///     colleague    gold TINT      `--brand-subtle` under the input-chip
    ///                                 ink, plus a gold EDGE always
    ///     other side   neutral tint   `Chip.neutralFill` under primary
    ///
    /// Gold is my farm's side, and solid against tinted is me against a
    /// colleague — the same family, plainly not the same object. The edge is
    /// what keeps a colleague's bubble from reading as the other side's in
    /// «Слънце», where both tints are faint; the caption over every bubble
    /// says who in words, so colour is never the only channel.
    ///
    /// No new token pairing is invented: the colleague's pair IS the input
    /// chip's (agri-saas#1331 explains its two-token ink), and the other
    /// side's was the bubble's before #1323. Bubble text is body size, so
    /// 4.5:1 applies; `PaletteTokenTests` measures each:
    ///
    ///     me                 8.45   5.21   5.21
    ///     colleague          7.33   5.29   5.83
    ///     other side        13.57  17.50  19.26
    ///
    /// The colleague's EDGE is `accentDeep`, a non-text boundary (3:1 against
    /// the page: 5.11 / 5.82 / 6.51, measured under `accentDeep on page`).
    enum Bubble {
        static let mineFill = accent
        static let mineInk = onAccent
        static let colleagueFill = Chip.inputFill
        static let colleagueInk = Chip.inputText
        static let colleagueEdge = accentDeep
        static let theirsFill = Chip.neutralFill
        static let theirsInk = Color.primary
    }

    /// The account card's initials circle — a FILL and the INK on it,
    /// defined together for the reason `onAccent` gives: the circle is the
    /// accent and the letters are `onAccent`.
    ///
    ///     ink on fill        8.45   5.21   6.19
    ///
    /// «Слънце» deepens the fill to `--brand-emphasis`, because Increase
    /// Contrast should raise this ratio and the highContrast arm's
    /// `--brand-default` is the same as light's. Dark keeps gold because gold
    /// is already the strongest of the pair; `--brand-emphasis` would drop
    /// it to 5.46.
    enum Avatar {
        static let fill = Color(token: { theme in
            theme == .highContrast ? AgrentColor.brandEmphasis(theme) : AgrentColor.brandDefault(theme)
        })

        static let ink = onAccent
    }

    /// The schematic map. Verified against the canvas value by value.
    enum Map {
        static let ground = Color(hex: 0x6E6A52)
        static let pathMajor = Color(hex: 0x8C8770)
        static let pathMinor = Color(hex: 0x7E7A63)
        static let sownFill = Color(hex: 0x3E8E4F)
        static let sownStroke = Color(hex: 0x2C6E3A)
        static let fallowFill = Color(hex: 0x9A9560)
        static let fallowStroke = Color(hex: 0x6F6B3E)
        static let label = Color.white
        /// WHAT GOES UNDER THE LABEL, because white alone does not carry it.
        ///
        /// A parcel name is drawn over whichever fill it lands on, and the
        /// fills are muted earth tones chosen for direct sunlight:
        ///
        ///     white on sown   #3E8E4F @0.55 over ground   4.70:1
        ///     white on fallow #9A9560 @0.55 over ground   3.93:1   fails
        ///     white on bare ground #6E6A52                5.46:1
        ///
        /// And with INCREASE CONTRAST on, where the fill goes to 0.92:
        ///
        ///     white on sown                               4.16:1
        ///     white on fallow                             3.20:1
        ///
        /// which is the part that matters. The near-solid fill was added for
        /// people who cannot separate two mid-tone colours, and it makes the
        /// text on top of it LESS readable, not more — the one setting in the
        /// app whose whole purpose is contrast was reducing it.
        ///
        /// A per-state ink would fix the numbers and not the problem: the
        /// placement solver nudges a colliding label down by up to four line
        /// heights, so a label can end up over the other state's fill, over
        /// bare ground, or straddling a boundary. An outline does not care
        /// what it lands on, which is why every map draws them.
        static let labelHalo = Color(hex: 0x0A1712)
        /// The coordinate grid. Shares the minor-path value deliberately —
        /// same family, no new colour introduced into a closed palette — but
        /// named separately because it means something else, and because
        /// path strokes will want their own value the day there is path data.
        static let graticule = Color(hex: 0x7E7A63)
        static let graticuleLabel = Color(hex: 0xC9C4A8)
        static let fillOpacity: Double = 0.55
        static let strokeWidth: CGFloat = 2.5
        static let dash: [CGFloat] = [7, 5]

        /// Increase Contrast is not a preference about taste. It is switched
        /// on by people who cannot reliably separate two mid-tone colours,
        /// and on this map the fill IS the data: #3E8E4F sown against
        /// #9A9560 fallow, both at 0.55 over a #6E6A52 ground, is three
        /// muted earth tones within a narrow band of each other. That is a
        /// deliberate choice for direct sunlight and the wrong one here.
        ///
        /// So the fill goes near-solid and the stroke thickens — the parcel
        /// stops being a tint over the ground and becomes a bordered object.
        /// The dashed/solid distinction is untouched because it already
        /// works: it is the non-colour channel, and it is what keeps the map
        /// readable in a monochrome screenshot.
        static func fillOpacity(_ contrast: ColorSchemeContrast) -> Double {
            contrast == .increased ? 0.92 : fillOpacity
        }

        static func strokeWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
            contrast == .increased ? 3.5 : strokeWidth
        }
    }
}

extension AgrentTheme {
    /// The token arm a trait collection gets — the table in `Palette`'s
    /// header, and the one place that decides it.
    ///
    /// Read from TRAITS rather than from `@Environment(\.colorScheme)`
    /// because a dynamic `UIColor` is what reaches a MapKit renderer or a
    /// UIKit appearance proxy, and the system asks it again whenever
    /// appearance or contrast changes, with no view having to re-render.
    static func current(_ traits: UITraitCollection) -> AgrentTheme {
        if traits.userInterfaceStyle == .dark { return .dark }
        return traits.accessibilityContrast == .high ? .highContrast : .light
    }
}

extension Color {
    /// One role, three token arms — resolved by the system per
    /// `AgrentTheme.current(_:)`.
    ///
    /// Pass a generated accessor directly (`Color(token:
    /// AgrentColor.bgPage)`). The three arms are converted once, here, so
    /// the provider the system calls on every trait change only picks one.
    init(token: (AgrentTheme) -> Color) {
        let dark = UIColor(token(.dark))
        let light = UIColor(token(.light))
        let high = UIColor(token(.highContrast))
        self.init(UIColor { traits in
            switch AgrentTheme.current(traits) {
            case .dark: return dark
            case .light: return light
            case .highContrast: return high
            }
        })
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
