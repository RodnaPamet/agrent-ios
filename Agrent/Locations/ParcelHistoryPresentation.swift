import Foundation

/// What the parcel-history screens SAY, and what each row of them amounts to
/// — kept out of the views so it can be tested without a rendering pass.
///
/// ── Why this is a separate file from the views ──
///
/// Everything the owner decided about this screen is a claim about text: a
/// count that must be absent while a cursor exists, a dose unit that must not
/// leave a trailing space, a separator that must not appear in front of an
/// absent product. None of that is testable through a SwiftUI body, and all
/// of it has shipped wrong in this app before — the trailing space on
/// `doseText` and the leading «·» in `LocationsView` were both valid strings
/// that no test could see.
///
/// So the strings are built here, from VALUES, and the views only place them.

// MARK: - The words

/// Every literal these screens show, in one place — hard-coded Bulgarian, the
/// same decision as everywhere else in this app (see `UserMessage`).
enum ParcelHistoryCopy {
    /// The three section names, exactly as the owner gave them.
    static let seasons = "РЕКОЛТИ"
    static let operations = "ДЕЙНОСТИ"
    static let weeds = "ПЛЕВЕЛИ"

    static let screenTitle = "История"

    /// The whole archive, empty. ONE line — not three cards each saying
    /// nothing, which is what a per-section empty state would produce for a
    /// parcel imported yesterday.
    static let emptyArchive = "Няма записана история за този парцел."

    /// One empty section, on its card. The card is NOT tappable in this
    /// state: pushing to an empty list is the same broken promise as a
    /// disabled button.
    static let emptySection = "Няма записи"

    static let loadOlder = "Покажи по-стари"

    /// Shown INSTEAD of the button once a paging attempt has ended a section.
    /// A control that silently vanishes on tap reads as a bug — the reader
    /// cannot tell "that was the end" from "that did not work".
    static let noOlder = "Няма по-стари записи."

    static let loading = "Зареждане…"
}

// MARK: - One row, as values

/// A row of the archive expressed as the VALUES it is made of, before
/// anything has been rendered.
///
/// ── Two outputs, one source ──
///
/// `text` is for the eye and joins with « · ». `spoken` is for VoiceOver and
/// joins with commas, through `A11y.sentence`. They are built from the same
/// parts rather than one from the other, which is the rule `A11y` exists to
/// enforce: five screens in this app built a label by combining rendered
/// children and VoiceOver read the separator aloud as "middle dot".
///
/// ── An absent part takes its separator with it ──
///
/// Every part is put through `String.recorded`, so empty and whitespace both
/// mean NOT RECORDED and are dropped — and because the join happens after the
/// drop, nothing is left holding a separator for a value that is not there.
/// This app has shipped that defect twice: `doseText` interpolated an empty
/// unit and left a trailing space, and `LocationsView` left a leading «·» in
/// front of a parcel count when `kind` was blank. Both produced valid
/// strings, which is why neither was caught by anything but a screenshot.
struct ParcelHistoryLine: Equatable {
    /// The leading value: a harvest YEAR, or a day and month. Never a label.
    let lead: String?
    /// What it was — a crop, a task title, the weeds seen.
    let headline: String?
    /// Beneath, in order. Only what was recorded.
    let details: [String]

    init(lead: String? = nil, headline: String? = nil, details: [String?] = []) {
        self.lead = lead?.recorded
        self.headline = headline?.recorded
        self.details = details.compactMap { $0?.recorded }
    }

    /// The first line, for the eye: « 2026 · Пшеница ».
    var text: String { Self.joined([lead, headline]) }

    /// The second line, for the eye: « Раундъп · 2,5 л/дка ».
    var detailText: String { Self.joined(details) }

    /// The values, in reading order, for anything assembling speech — so a
    /// caller that has more to say (a card's section name and count) can put
    /// its own parts alongside these instead of nesting one finished sentence
    /// inside another.
    var parts: [String?] { [lead, headline] + details }

    /// The whole row, for VoiceOver, from the values — never from `text`,
    /// which carries typography the audio channel has no business hearing.
    var spoken: String { A11y.sentence(parts) }

    /// Nothing was recorded at all. Possible in principle — a completed line
    /// whose task, product and date are all absent — and the row then shows
    /// what little it has rather than a placeholder, so the view uses this to
    /// decide whether it has a label worth declaring.
    var isBlank: Bool { lead == nil && headline == nil && details.isEmpty }

    /// Joins what was recorded with « · », and draws NO separator for what
    /// was not.
    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0?.recorded }.joined(separator: " · ")
    }
}

// MARK: - The three kinds of row

extension CropSeason {
    /// « 2026 · Пшеница » — the HARVEST year leading, as the owner asked, and
    /// read from `year` rather than derived from `sownAt`.
    ///
    /// The derivation is the trap the model's own header spells out: wheat
    /// drilled in October 2025 is the 2026 harvest, so taking the year from
    /// the sowing date misfiles most autumn cropping in Bulgaria by exactly
    /// one year — every row still plausible, only the totals nonsense.
    ///
    /// `String(year)` and not a formatter: a year is a label, not a quantity,
    /// and a grouping separator would print « 2 026 ».
    var historyLine: ParcelHistoryLine {
        ParcelHistoryLine(lead: String(year), headline: cropLabel)
    }
}

extension ParcelHistoryOperation {
    /// « 3 май · Хербицид » over « Раундъп · 2,5 л/дка ».
    ///
    /// All four parts can be missing and each goes missing differently:
    /// `completedAt` is optional on the wire, `title` and `productName` are
    /// `?? ''` collapses the schema cannot distinguish from a recorded value,
    /// and `doseUnit` is an empty string that MEANS "no unit". Every one of
    /// them is simply left out, with no placeholder and no separator — see
    /// `ParcelHistoryLine`.
    var historyLine: ParcelHistoryLine {
        ParcelHistoryLine(
            lead: completedAt.map(BgDate.dayMonth),
            headline: title,
            details: [productName, doseText]
        )
    }
}

extension WeedObservation {
    /// « 11 юни » over the weeds seen, joined with ", ".
    ///
    /// `displayNames` already renders a catalogue weed as
    /// « балур (Sorghum halepense) » and free text verbatim, and already puts
    /// the catalogue half first. Nothing here re-orders or re-translates it:
    /// the split between the two halves is the server's, and the free-text
    /// half is whatever somebody typed.
    ///
    /// The join is ", " rather than " · " on the owner's instruction, and it
    /// is also the only separator that is safe to speak — which is why this
    /// whole list is ONE part of the line rather than one part per weed.
    var historyLine: ParcelHistoryLine {
        ParcelHistoryLine(
            lead: observedAt.map(BgDate.dayMonth),
            headline: displayNames.joined(separator: ", ")
        )
    }
}

// MARK: - The end of a drill-in list

/// What the bottom of a section's full list shows.
///
/// A pure value so the four states can be pinned by a test. Written as a
/// `switch` in a view body they could only be checked by looking, and three of
/// the four are states a reader reaches by tapping something and waiting.
enum ParcelHistoryPaging: Equatable {
    /// NOTHING AT ALL — and this is the ordinary case for a short archive.
    ///
    /// `exhausted` is set by what ARRIVED, so it is false for a section that
    /// came whole in its first page. No control was ever offered there, so
    /// there is nothing to explain away; the card upstairs carries that
    /// section's exact count, which says it better than a sentence would.
    case nothing

    /// A page is in flight for THIS section. Per-section, because the three
    /// page independently and a shared spinner would claim the other two were
    /// busy.
    case spinner

    /// «Покажи по-стари» — explicit, not infinite scroll. Loading on scroll
    /// fetches pages nobody asked for on a connection this app assumes is bad.
    case button

    /// «Няма по-стари записи.» — the end, stated.
    ///
    /// A control that vanishes when tapped reads as a bug: the reader cannot
    /// tell "that was the end" from "that did not work". This is what replaces
    /// the button once a paging attempt has ended the section, which includes
    /// the case where the server answered with a page carrying nothing new.
    case end

    init<Item: Identifiable & Equatable & Sendable>(
        _ section: ParcelHistoryStore.Section<Item>
    ) where Item.ID == String {
        // Order matters: `canLoadOlder` is already false while a page is in
        // flight, and false once exhausted, so the spinner is asked about
        // first and the end last.
        if section.isLoadingOlder {
            self = .spinner
        } else if section.canLoadOlder {
            self = .button
        } else if section.exhausted {
            self = .end
        } else {
            self = .nothing
        }
    }
}

// MARK: - One card on the summary screen

/// A section's card: its name, its newest entry, and a count only when a
/// count can be made honestly.
///
/// ── Why the count is usually absent ──
///
/// The envelope carries NO TOTAL. It carries up to 100 rows and a cursor, so
/// the only number available is "how many are loaded", and rendering that as
/// « 100+ » would read as "more than 100" — the one thing it does not mean.
///
/// Worse, a cursor is not even a strict has-more flag: the server hands one
/// back for the last row of the page it just sent, so a section whose length
/// divides exactly by the page size returns a cursor for a page that turns
/// out to be empty. « 100+ » would then be a lie about a section holding
/// exactly 100 rows.
///
/// So: a count when the section arrived whole, and otherwise NO COUNT AT ALL
/// — no «+», no footnote, no explanatory band. Making no claim beats a claim
/// that needs a footnote, and the owner has had explanatory bands stripped
/// off other screens already.
///
/// ── The one case this leaves on the table ──
///
/// `Section.exhausted` can become true while the cursor is still non-nil:
/// that is the empty-page ending above. The section really is complete then,
/// and a count would be true — but the rule the owner gave names the cursor,
/// and "no count" is not a false claim, only a quiet one. Left as the rule
/// was given rather than widened here.
struct ParcelHistoryCard: Equatable {
    let title: String

    /// « 3 записа », or NIL MEANING SAY NOTHING. Never a placeholder.
    let count: String?

    /// The newest entry, or nil when the section holds none.
    ///
    /// NEWEST IS `items.first`. The order is the server's — the store never
    /// sorts, and `appendOlder` appends — so the head of the array is the
    /// newest row and a client-side sort would interleave paged rows into
    /// pages already on screen.
    let newest: ParcelHistoryLine?

    /// An empty section's card does not push. Pushing to an empty list is the
    /// same broken promise as a disabled button, and the card already says
    /// «Няма записи» in place of the entry it does not have.
    var isTappable: Bool { newest != nil }

    init<Item: Identifiable & Equatable & Sendable>(
        title: String,
        section: ParcelHistoryStore.Section<Item>,
        line: (Item) -> ParcelHistoryLine
    ) where Item.ID == String {
        self.title = title
        self.newest = section.items.first.map(line)

        // A count for an EMPTY complete section would be « 0 записа » beside
        // «Няма записи» — the same fact twice, once as a number. The card
        // says it in words instead.
        self.count = section.cursor == nil && !section.items.isEmpty
            ? Plural.bg(section.items.count, "запис", "записа")
            : nil
    }
}
