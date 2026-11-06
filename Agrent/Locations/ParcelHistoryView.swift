import SwiftUI

/// A parcel's archive: what it grew, what was applied to it, and what was
/// growing there that nobody planted.
///
/// ── Summary, then drill in ──
///
/// One compact card per section — newest entry plus a chevron — and tapping a
/// card pushes the full list. The alternative, three full lists on one screen,
/// puts the reader in a place where the answer to "what was sprayed here" is
/// an unknown distance down a scroll shared with two other timelines.
///
/// The three sections do NOT merge into one feed. A season is a YEAR, an
/// operation is an INSTANT, an observation is a DAY somebody walked the field;
/// merging them reads well on a mock and loses the only thing each is good for.
/// That is `ParcelHistoryModels`' decision and this screen keeps it.
///
/// ── Where it is reached from, and where it is deliberately not ──
///
/// From a row on Риск по парцели. NOT from `ParcelOperationSheet`, which the
/// map tap opens: that sheet is a form to RECORD an operation and the tap is
/// gated on `mayCreateOperations`, which is false for MECHANISATOR, READER and
/// AUDITOR. Putting the archive there would have buried it in a create form
/// and hidden it from the operator who sprayed the field.
///
/// ── And the parcel's risk, from Блокове (owner, 2026-10-29) ──
///
/// Opened from Блокове, the screen starts with «Риск»: the parcel's reading
/// as Риск shows it (`ParcelRiskReadings`). Not when opened from Риск, which
/// has just shown it.
///
/// Then «Задачи» (#462, same day): a card with the newest current task,
/// opening the parcel's tasks, «Текущи» and «Архив» (`ParcelTasksView`).
/// From Блокове too, as it was asked for there.
///
/// And «Коментари» (#465, same day): the comments on the parcel's tasks and
/// their closing notes, from wherever the screen is opened, as they are its
/// history (`ParcelCommentsView`).
///
/// ── «+», per section (owner, 2026-11-06) ──
///
/// Each section's list has a «+» at the top right that makes one of its
/// own, and the screen has a menu of all four (`Create`). A wrong season or
/// observation is swiped away («Изтрий», #541, `HistoryRemoval`) and
/// recorded again; edit waits for the server's PATCH (#542).
struct ParcelHistoryView: View {
    /// The name as the Риск row already knew it, so the header is not blank
    /// for the length of the first request. The archive's own name wins once
    /// it arrives — the server's is authoritative if the parcel was renamed.
    private let parcelName: String
    private let parcelID: String

    /// ONE STORE, owned here and handed to every drill-in.
    ///
    /// The cards and the lists they open therefore read the same `Section`
    /// values, so a card cannot claim a newest entry the list it pushes does
    /// not show, and a page loaded in a list is on the card when the reader
    /// comes back.
    @State private var store: ParcelHistoryStore

    /// The parcel in its block, from Блокове's map (#387) and, since
    /// 2026-11-06, from Риск's block (`RiskHistoryRoute`). Then «Ново
    /// мероприятие» and «Нова задача» are here, and the parcel's tasks.
    private let recordIn: ParcelInBlock?
    /// The parcel's outline, for the map at the top (owner, 2026-11-06).
    private let outline: Parcel?
    /// РЕКОЛТИ's and ПЛЕВЕЛИ's «Изтрий» (owner, 2026-11-06, #541), one for
    /// both lists, so a delete waiting in one is still hidden on return.
    @State private var removal: HistoryRemoval
    /// The «+» that is open, and which screen it is on (`creatingSheets`).
    @State private var creating: Creating?
    /// Who is signed in: which «+» to offer.
    @State private var people = CurrentUserStore.shared
    /// A season, an operation or an observation saved from its sheet.
    /// Played here, because the sheet closes on success (`WriteFeedback`).
    @State private var feedback = WriteFeedback()

    /// The parcel's risk reading, when opened from Блокове (owner,
    /// 2026-10-29). Nil from Риск (`fromRisk`), which has just shown it.
    @State private var risk: ParcelRiskStore?
    /// The parcel's tasks, from Блокове (#462). One store for the card and
    /// the list it opens.
    @State private var tasks: ParcelTasksStore?
    /// The comments on the parcel's tasks and their closing notes (#465),
    /// part of its history, so from wherever the screen is opened.
    @State private var comments: ParcelCommentsStore

    init(parcelID: String, parcelName: String, recordIn: ParcelInBlock? = nil, outline: Parcel? = nil,
         fromRisk: Bool = false) {
        self.parcelName = parcelName
        self.parcelID = parcelID
        self.recordIn = recordIn
        self.outline = outline ?? recordIn?.parcel
        _store = State(initialValue: ParcelHistoryStore(parcelID: parcelID))
        _risk = State(initialValue: recordIn == nil || fromRisk ? nil : ParcelRiskStore(parcelID: parcelID))
        _tasks = State(initialValue: recordIn == nil ? nil : ParcelTasksStore(parcelID: parcelID))
        _comments = State(initialValue: ParcelCommentsStore(parcelID: parcelID))
        _removal = State(initialValue: HistoryRemoval(parcelID: parcelID))
    }

    var body: some View {
        content
            .inlineTitle(ParcelHistoryCopy.screenTitle)
            // Once, on the screen, outside the List: a destination declared
            // inside a lazy row would come and go with the row.
            .navigationDestination(for: DrillIn.self) { list($0) }
            // EAGERLY, HERE — and cache-first through the store, which is
            // what makes reopening this screen instant on a bad connection.
            //
            // Deliberately not in the Риск list: fetching an archive per row
            // would be one request per parcel for data nobody asked to see,
            // on a connection this app assumes is poor.
            .task {
                if store.state.value == nil { await store.load() }
            }
            .task { _ = await people.load() }
            .task { await risk?.load() }
            .task { await tasks?.load() }
            .task { if comments.state.value == nil { await comments.load() } }
            .toolbar { addMenu }
            .modifier(creatingSheets(on: nil))
            .writeFeedback(feedback)
    }

    // MARK: - Making a new one

    /// What a «+» here makes (owner, 2026-11-06): "in each section there
    /// should be a '+' action button on the top right to create a new
    /// entry". РЕКОЛТИ a crop season, ДЕЙНОСТИ an operation, ПЛЕВЕЛИ a weed
    /// observation, Задачи a task for this parcel. In the screen's order.
    fileprivate enum Create: Hashable, CaseIterable {
        case season, operation, weeds, task

        var title: String {
            switch self {
            case .season: ParcelHistoryCopy.cropsAdd
            case .operation: "Ново мероприятие"
            case .weeds: ParcelHistoryCopy.weedsAdd
            case .task: "Нова задача"
            }
        }

        var spoken: [String] {
            switch self {
            case .season: A11y.Spoken.addCrop
            case .operation: A11y.Spoken.newOperation
            case .weeds: A11y.Spoken.addWeeds
            case .task: A11y.Spoken.newTask
            }
        }

        /// A section's own; nil for «Коментари», which are written on tasks.
        init?(_ drillIn: DrillIn) {
            switch drillIn {
            case .seasons: self = .season
            case .operations: self = .operation
            case .weeds: self = .weeds
            case .tasks: self = .task
            case .comments: return nil
            }
        }
    }

    /// Who may, and from where.
    ///
    /// A season and an observation are the parcel's alone, so any writer
    /// may, from wherever the history was opened (`assertCanWrite`). An
    /// operation and a task need the parcel's block, which only Блокове's
    /// map gives (`recordIn`): an operation is recorded IN a block, and a
    /// task's parcels are chosen by block. An operation for someone who may
    /// create one (`mayCreateOperations`, failing open, as the map's tap
    /// did); the rest for someone who may write, as «Задачи»'s + is.
    private func offers(_ kind: Create) -> Bool {
        switch kind {
        case .season, .weeds: people.user?.mayWrite ?? true
        case .operation: recordIn != nil && (people.user?.mayCreateOperations ?? true)
        case .task: recordIn != nil && (people.user?.mayWrite ?? true)
        }
    }

    /// A section list's «+», the rightmost item in its bar (`ScreenAction`).
    @ToolbarContentBuilder
    private func createAction(_ kind: Create?, on drillIn: DrillIn) -> some ToolbarContent {
        if let kind, offers(kind) {
            ScreenAction(title: kind.title, spoken: kind.spoken) {
                creating = Creating(kind: kind, on: drillIn)
            }
        }
    }

    /// The history's own «+», where «Ново мероприятие»'s wide bar was: a
    /// menu of what the person may make, as the screen's sections run, since
    /// one screen holds four sections. A section with nothing in it has no
    /// list to open, so this is the way to its first entry.
    @ToolbarContentBuilder
    private var addMenu: some ToolbarContent {
        let kinds = Create.allCases.filter(offers)
        if !kinds.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(kinds, id: \.self) { kind in
                        Button(kind.title) { creating = Creating(kind: kind, on: nil) }
                            .accessibilityInputLabels(kind.spoken)
                    }
                } label: {
                    Label("Добави", systemImage: "plus")
                }
                .accessibilityLabel("Добави")
                .accessibilityInputLabels(A11y.Spoken.add)
            }
        }
    }

    /// One sheet's presence, on one screen.
    private func shows(_ kind: Create, on drillIn: DrillIn?) -> Binding<Bool> {
        Binding(get: { creating == Creating(kind: kind, on: drillIn) },
                set: { if !$0 { creating = nil } })
    }

    /// The sheets, presented from the screen the «+» is on: the history, or
    /// the section list pushed over it. One `creating`, read by each
    /// presenter only when it names that presenter, so the screen under a
    /// list never tries to present the same sheet as the list.
    private func creatingSheets(on drillIn: DrillIn?) -> CreatingSheets {
        CreatingSheets(
            season: shows(.season, on: drillIn), operation: shows(.operation, on: drillIn),
            weeds: shows(.weeds, on: drillIn), task: shows(.task, on: drillIn),
            parcelID: parcelID,
            recordIn: recordIn,
            onRecorded: {
                feedback.saved()
                Task { await store.refresh() }
            },
            reloadTasks: { await tasks?.load() })
    }


    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView(ParcelHistoryCopy.loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            // `.failed` means there was nothing cached to fall back on, so
            // this is the genuinely empty-handed case — the only one that
            // gets the error treatment and a way out. The risk is its own
            // read, so it stays above the failure rather than going with it.
            VStack(alignment: .leading, spacing: 0) {
                // The outline comes with the route, not the archive: shown
                // whether or not the archive could be read.
                if let outline, outline.geometry?.hasDrawableRing == true {
                    ParcelOutlineMap(parcel: outline)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                if let risk {
                    riskSection(risk)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                if let tasks {
                    tasksCard(tasks, inList: false)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                commentsCard(inList: false)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                ErrorState(message: message) { await store.load() }
            }

        case .loaded(let archive, _):
            List {
                // Each helper below puts its own rows on the page; this
                // `Group` does it once more for the whole list, so a row
                // added here later is on the page too, and the per-list
                // check in `FormSurfaceTests` can see it from the list (#164).
                Group {
                    header(archive)
                    if let outline, outline.geometry?.hasDrawableRing == true {
                        ParcelOutlineMap(parcel: outline)
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                    }
                    if let risk { riskSection(risk) }
                    if let tasks { tasksCard(tasks, inList: true) }
                    commentsCard(inList: true)
                    // The three cards even for an empty archive (owner,
                    // 2026-11-06): each opens onto its «+». It was one line,
                    // «Няма записана история…», with nothing to tap.
                    cards(archive)
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            // REFRESH LIVES HERE AND NOWHERE DEEPER.
            //
            // `refresh()` replaces the archive by design — stitching a fresh
            // first page onto pages read ten minutes ago produces a list with
            // a gap in the middle that nothing on screen could explain. On a
            // drill-in the same gesture would silently discard pages the
            // reader had just asked for, so the drill-ins have none.
            .refreshable {
                await PullToRefresh.bounded {
                    await store.refresh()
                    await tasks?.load()
                    await comments.load()
                }
            }
        }
    }

    // MARK: - Which parcel

    /// The parcel's name, and deliberately nothing else.
    ///
    /// `ParcelHistory.ParcelRef` also carries `cropType` — the CURRENT crop,
    /// one overwritten field with no year attached to it. The server is
    /// explicit that a client must not read that as part of the archive, and
    /// on a screen whose first card is a list of crops by harvest year it
    /// would read as exactly that. So it stays off: РЕКОЛТИ is the record,
    /// and the label on the parcel is not.
    private func header(_ archive: ParcelHistoryStore.Archive) -> some View {
        Text(archive.parcel.name.recorded ?? parcelName)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .listRowSeparator(.hidden)
            .pageRow()
    }

    // MARK: - Risk

    /// «Риск», the parcel's reading as Риск shows it (`ParcelRiskReadings`),
    /// above the archive: what the field looks like now, then what was done
    /// to it. Nothing while it loads; a failure is one quiet line, as on Риск.
    @ViewBuilder
    private func riskSection(_ risk: ParcelRiskStore) -> some View {
        switch risk.state {
        case .loading:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Риск", font: ParcelHistoryCopy.sectionTitleFont)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        case .loaded(let reading, let freshness):
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Риск", font: ParcelHistoryCopy.sectionTitleFont)
                ParcelRiskReadings(risk: reading, freshness: freshness)
            }
            .padding(.vertical, 6)
            // One stop, said from the values, as a Риск row is.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(A11y.sentence(["Риск"] + ParcelRiskReadings.spoken(reading, freshness)))
        }
    }

    // MARK: - The three cards

    /// Which list a card opens (agrent-ios#194): a VALUE on the stack's path,
    /// because the stack this screen is pushed onto takes values only — see
    /// `RoutedStack`. Its own type and destination, declared on this screen
    /// rather than as an `AppRoute`: the lists share this screen's store,
    /// which nothing outside the screen should hold.
    fileprivate enum DrillIn: Hashable { case seasons, operations, weeds, tasks, comments }

    fileprivate struct Creating: Equatable {
        let kind: Create
        let on: DrillIn?
    }

    @ViewBuilder
    private func cards(_ archive: ParcelHistoryStore.Archive) -> some View {
        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.seasons,
                section: archive.seasons,
                line: { $0.historyLine }
            ),
            opens: .seasons
        )

        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.operations,
                section: archive.operations,
                line: { $0.historyLine }
            ),
            opens: .operations
        )

        cardRow(
            ParcelHistoryCard(
                title: ParcelHistoryCopy.weeds,
                section: archive.weeds,
                line: { $0.historyLine }
            ),
            opens: .weeds
        )
    }

    /// The list a card opens, over the same store the cards read, with its
    /// section's «+».
    private func list(_ drillIn: DrillIn) -> some View {
        sectionList(drillIn)
            .toolbar { createAction(Create(drillIn), on: drillIn) }
            .modifier(creatingSheets(on: drillIn))
    }

    @ViewBuilder
    private func sectionList(_ drillIn: DrillIn) -> some View {
        switch drillIn {
        case .seasons:
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.seasons,
                parcelName: parcelName,
                part: .seasons,
                store: store,
                section: { $0.seasons },
                line: { $0.historyLine },
                removal: removal,
                target: { HistoryRemoval.Target($0) }
            )
        case .operations:
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.operations,
                parcelName: parcelName,
                part: .operations,
                store: store,
                section: { $0.operations },
                line: { $0.historyLine }
            )
        case .weeds:
            ParcelHistorySectionList(
                title: ParcelHistoryCopy.weeds,
                parcelName: parcelName,
                part: .weeds,
                store: store,
                section: { $0.weeds },
                line: { $0.historyLine },
                removal: removal,
                target: { HistoryRemoval.Target($0) }
            )
        case .tasks:
            if let tasks {
                ParcelTasksView(parcelName: parcelName, store: tasks)
            }
        case .comments:
            ParcelCommentsView(parcelName: parcelName, store: comments)
        }
    }

    // MARK: - Tasks

    /// «Задачи»: the newest current task and how many there are, opening
    /// both tabs. Nothing while it loads; a failure is one quiet line, as
    /// «Риск» above it.
    ///
    /// `inList` is false above a failed archive, where the card is a link
    /// outside a List: plain, or the link's tint turns its text gold, and
    /// with a chevron of its own, as no row draws one there.
    @ViewBuilder
    private func tasksCard(_ tasks: ParcelTasksStore, inList: Bool) -> some View {
        switch tasks.state {
        case .loading:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(ParcelTasksCard.title, font: ParcelHistoryCopy.sectionTitleFont)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        case .loaded(let list, _):
            summaryCard(ParcelTasksCard(list), opens: .tasks, inList: inList)
        }
    }

    // MARK: - Comments

    /// «Коментари»: the newest comment or closing note, and how many, opening
    /// them all. Quiet while it loads and on a failure, as «Задачи» is.
    @ViewBuilder
    private func commentsCard(inList: Bool) -> some View {
        switch comments.state {
        case .loading:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(ParcelCommentsCard.title, font: ParcelHistoryCopy.sectionTitleFont)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        case .loaded(let list, _):
            summaryCard(ParcelCommentsCard(list), opens: .comments, inList: inList)
        }
    }

    /// A summing card and its push, when there is something to push to.
    @ViewBuilder
    private func summaryCard(_ card: some ParcelSummaryCard, opens drillIn: DrillIn, inList: Bool) -> some View {
        if !card.isTappable {
            summaryCardBody(card, chevron: false)
        } else if inList {
            NavigationLink(value: drillIn) { summaryCardBody(card, chevron: false) }
        } else {
            NavigationLink(value: drillIn) { summaryCardBody(card, chevron: true) }
                .buttonStyle(.plain)
        }
    }

    /// The history cards' look (`cardBody`), for a summing card's values.
    private func summaryCardBody(_ card: some ParcelSummaryCard, chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(card.title, font: ParcelHistoryCopy.sectionTitleFont)
                Spacer(minLength: 8)
                if let count = card.count {
                    Text(count)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            if !card.line.text.isEmpty {
                Text(card.line.text)
                    .font(.headline)
                    .lineLimit(card.headlineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.line.detailText.isEmpty {
                Text(card.line.detailText)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        // One stop, spoken from the values, as the history cards are.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.spoken)
    }

    /// A card, and a push only when there is something to push to.
    ///
    /// An empty section renders the same card WITHOUT the link — so no
    /// chevron, no highlight, nothing that reads as a promise. Pushing to an
    /// empty list is the same broken promise as a disabled button.
    @ViewBuilder
    private func cardRow(_ card: ParcelHistoryCard, opens drillIn: DrillIn) -> some View {
        if card.isTappable {
            NavigationLink(value: drillIn) { cardBody(card) }
                .pageRow()
        } else {
            cardBody(card)
                .pageRow()
        }
    }

    private func cardBody(_ card: ParcelHistoryCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(card.title, font: ParcelHistoryCopy.sectionTitleFont)
                Spacer(minLength: 8)
                // THE COUNT, OR NOTHING AT ALL.
                //
                // Nothing is the usual case: the envelope carries no total,
                // so a count is only available for a section that arrived
                // whole. See `ParcelHistoryCard` for why « 100+ » would be a
                // claim this data cannot support, and why no footnote is
                // offered in its place.
                if let count = card.count {
                    Text(count)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            if let newest = card.newest {
                if !newest.text.isEmpty {
                    Text(newest.text)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !newest.detailText.isEmpty {
                    Text(newest.detailText)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(ParcelHistoryCopy.emptySection)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 4)
        // ONE STOP PER CARD, SPOKEN FROM THE VALUES.
        //
        // `children: .combine` would read the rendered text, which carries
        // the « · » between a year and its crop — "2026 middle dot Пшеница".
        // The separator is typography and has no business in the audio
        // channel, which is the lesson `A11y` was written to hold.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(
            [card.title, card.count] + (card.newest?.parts ?? [ParcelHistoryCopy.emptySection])
        ))
    }
}

/// The history's «+» sheets, on whichever screen presents them: a crop
/// season and a weed observation for the parcel, «Ново мероприятие» for the
/// parcel in its block, and «Нова задача» with the parcel chosen
/// (`NewTaskComposer`, which opens the task it makes on this stack).
private struct CreatingSheets: ViewModifier {
    @Binding var season: Bool
    @Binding var operation: Bool
    @Binding var weeds: Bool
    @Binding var task: Bool
    let parcelID: String
    let recordIn: ParcelInBlock?
    /// A season, an observation or an operation saved: the archive again.
    let onRecorded: () -> Void
    let reloadTasks: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $season) {
                NewCropSeasonSheet(parcelID: parcelID, onSaved: onRecorded)
            }
            .sheet(isPresented: $operation) {
                if let recordIn {
                    ParcelOperationSheet(locationID: recordIn.locationID, parcel: recordIn.parcel, onSaved: onRecorded)
                }
            }
            .sheet(isPresented: $weeds) {
                NewWeedObservationSheet(parcelID: parcelID, onSaved: onRecorded)
            }
            .newTaskComposer(isPresented: $task, preset: recordIn, reload: reloadTasks)
    }
}
