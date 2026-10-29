import Foundation

/// A card on a parcel's screen that sums up a list and opens it: «Задачи»
/// and «Коментари». The history cards' look, for lists that aren't the
/// archive's own sections.
protocol ParcelSummaryCard {
    var title: String { get }
    var count: String? { get }
    var line: ParcelHistoryLine { get }
    var isTappable: Bool { get }
    var spoken: String { get }
    /// How many lines the first line may take on the card; nil for all.
    var headlineLimit: Int? { get }
}

extension ParcelSummaryCard {
    var headlineLimit: Int? { nil }
}

extension ParcelTasksCard: ParcelSummaryCard {
    var title: String { Self.title }
}

/// What the «Коментари» card on a parcel's screen says, from values (#465,
/// owner 2026-10-29: «history (incl. comment)»).
struct ParcelCommentsCard: Equatable, ParcelSummaryCard {
    static let title = "Коментари"
    var title: String { Self.title }

    /// «3 коментара», or nothing when there are none, which the line says,
    /// or when the server capped the list.
    let count: String?
    /// The newest comment: what it says, then who (or that it is a closing
    /// note), the day, and the task it is on.
    let line: ParcelHistoryLine
    let isTappable: Bool
    /// A long comment is the list's to show in full.
    var headlineLimit: Int? { 3 }

    init(_ comments: ParcelComments, now: Date = Date()) {
        if let newest = comments.items.first {
            isTappable = true
            count = comments.truncated ? nil : Plural.bg(comments.items.count, "коментар", "коментара")
            line = ParcelHistoryLine(headline: newest.text, details: [
                newest.who,
                newest.createdAt.map { BgDate.rowDay($0, now: now) },
                newest.task,
            ])
        } else {
            isTappable = false
            count = nil
            line = ParcelHistoryLine(details: ["Няма коментари"])
        }
    }

    var spoken: String { A11y.sentence([Self.title, count] + line.parts) }
}
