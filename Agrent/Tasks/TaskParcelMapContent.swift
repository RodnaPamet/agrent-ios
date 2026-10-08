import MapKit

/// What a task's map draws (agrent-ios#177): the task's own parcels, each
/// marked, over the rest of their location's parcels.
///
/// ── Why the rest of the location is drawn at all ──
///
/// A parcel alone on imagery says what it looks like, not where it is among
/// the farm's other fields — and where is the question someone heading out to
/// do the task is asking. The other parcels are thin outlines only, so they
/// place the task's parcels without competing with them, and the camera frames
/// the task's parcels rather than the whole location. The web's spray map
/// draws the whole location alike and shades only the finished parcels; this
/// one marks every parcel the task is about.
///
/// ── A value, so the rules are tests ──
///
/// Which parcel gets which mark, what counts as drawable and what is said
/// aloud are decided here, away from MapKit, where a unit test can reach them.
struct TaskParcelMapContent: Equatable {
    struct Marked: Equatable, Identifiable {
        let parcel: Parcel
        let mark: TaskParcelMark
        var id: String { parcel.id }
    }

    /// The task's parcels that have an outline, in the task's own order.
    let marked: [Marked]

    /// The location's OTHER parcels that have an outline.
    let context: [Parcel]

    /// The task's parcels the map cannot draw: no geometry, or none the
    /// server could parse (`Parcel.geometry`). Said under the map, because a
    /// parcel silently missing from it reads as a parcel the task is not about.
    let undrawable: Int

    /// nil when none of the task's parcels can be drawn. A map of only the
    /// location's other fields would show the task as being about them.
    ///
    /// `marks` is in the task's order; a parcel named twice keeps its first
    /// mark — the callers have already folded each parcel to one.
    init?(parcels: [Parcel], marks: [(parcelID: String, mark: TaskParcelMark)]) {
        let byID = Dictionary(parcels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var marked: [Marked] = []
        var undrawable = 0
        var seen = Set<String>()
        for (id, mark) in marks where seen.insert(id).inserted {
            if let parcel = byID[id], parcel.isDrawable {
                marked.append(Marked(parcel: parcel, mark: mark))
            } else {
                undrawable += 1
            }
        }
        guard !marked.isEmpty else { return nil }
        self.marked = marked
        self.context = parcels.filter { $0.isDrawable && !seen.contains($0.id) }
        self.undrawable = undrawable
    }

    /// The task's parcels, framed the way every map in the app frames:
    /// padded, and floored so one small parcel does not zoom to street level.
    /// `.bulgaria` cannot happen here — `init` refuses content with nothing
    /// drawable — but a camera must not be optional.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(fitting: marked.map(\.parcel)) ?? .bulgaria
    }

    /// The marks on the map, in the legend's order.
    var legend: [TaskParcelMark] {
        TaskParcelMark.allCases.filter { mark in marked.contains { $0.mark == mark } }
    }

    /// One VoiceOver stop for the whole map, which is an image to everyone
    /// else: which parcels are on it and in what state, by NAME — the lines
    /// under it say the rest, and a count alone would not say which field.
    ///
    /// A sentence per state rather than one comma-joined list: the names
    /// inside a state are already comma-separated, and a listener has no
    /// other way to hear where «Готово» stops applying.
    var spokenSummary: String {
        var sentences = ["Карта на парцелите."]
        for mark in legend {
            let names = marked.filter { $0.mark == mark }.map(\.parcel.name)
            sentences.append("\(mark.label): \(names.joined(separator: ", ")).")
        }
        if let note = Self.undrawableNote(undrawable) { sentences.append(note) }
        return sentences.joined(separator: " ")
    }

    /// «1 парцел няма очертания и не е на картата.»
    static func undrawableNote(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 парцел няма очертания и не е на картата."
        default: "\(count) парцела нямат очертания и не са на картата."
        }
    }
}

extension TaskParcelMapContent {
    /// A field operation's map: each parcel marked by its lines AS SHOWN — a
    /// mark still waiting on the phone counts, as it does in the list under
    /// the map, so the two cannot disagree about a parcel.
    ///
    /// `parcels` is every parcel of the job's location (the route's map
    /// backdrop); the job's own are the lines'.
    static func fieldOperation(parcels: [Parcel], rows: [LineState]) -> TaskParcelMapContent? {
        var order: [String] = []
        var shown: [String: [OperationLineStatus]] = [:]
        for row in rows {
            let id = row.line.parcel.id
            if shown[id] == nil { order.append(id) }
            shown[id, default: []].append(row.shown)
        }
        return TaskParcelMapContent(
            parcels: parcels,
            marks: order.map { (parcelID: $0, mark: TaskParcelMark(lines: shown[$0] ?? [])) })
    }

    /// Any other task's map: every parcel the task links, all marked alike,
    /// in the route's order (by name).
    ///
    /// No backdrop. `GET /tasks/{id}/parcels` sends the task's own parcels
    /// and no location with them, so there is nothing to place them among —
    /// the camera frames them on the imagery, which is still where they are.
    static func linked(_ parcels: [Parcel]) -> TaskParcelMapContent? {
        TaskParcelMapContent(parcels: parcels, marks: parcels.map { (parcelID: $0.id, mark: .linked) })
    }
}

/// How one of a task's parcels is drawn.
enum TaskParcelMark: CaseIterable, Equatable, Sendable {
    /// A field-operation parcel with work still to do.
    case pending
    case done
    case skipped
    /// A parcel some other kind of task is about. No state to show — the
    /// task's own status says how far along it is.
    case linked

    /// ONE PARCEL, SEVERAL LINES: a job prescribes one line per product, so
    /// a parcel sprayed with two has two. It is still to do while ANY line
    /// is; otherwise done if any line was done, and skipped only when every
    /// line was skipped — a parcel where one product went on was worked.
    init(lines: [OperationLineStatus]) {
        if lines.contains(where: { !$0.isComplete }) {
            self = .pending
        } else if lines.contains(.done) {
            self = .done
        } else {
            self = .skipped
        }
    }

    /// The lines' own words (`OperationLineStatus.label`), so the legend and
    /// the chips under it name a state the same way.
    var label: String {
        switch self {
        case .pending: OperationLineStatus.pending.label
        case .done: OperationLineStatus.done.label
        case .skipped: OperationLineStatus.skipped.label
        case .linked: "Парцели на задачата"
        }
    }
}
