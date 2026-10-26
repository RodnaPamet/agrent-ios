import SwiftUI

struct JournalListView: View {
    @State private var store = JournalStore()
    @State private var composing = false
    /// «Дневник (PDF)» is up (#246).
    @State private var exportingRecord = false
    /// «Филтри» is up (#252).
    @State private var filtering = false
    /// The blocks and crops the filter offers, read once for this screen.
    @State private var filterOptions = JournalFilterOptions()
    /// Whose role decides whether «Нов запис» is offered.
    @State private var people = CurrentUserStore.shared
    /// Treatments kept on the phone, shown above the entries (#324).
    @State private var outbox = OutboxStore.shared
    /// A treatment abandoned from its entry's screen (#326): read again.
    @State private var changes = JournalChanges.shared
    /// Rows swiped away, inside their five seconds or just sent (#395).
    @State private var removal = TreatmentRemoval()
    /// A swipe the server refused is being said (#395).
    @State private var refused = false
    /// The row whose «Изтрий» is being asked about (owner, 2026-10-26).
    @State private var confirmingRemoval: LogEntry?
    @State private var confirming = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    /// The rows the list shows: the server's, less what was swiped away.
    private func visible(_ entries: [LogEntry]) -> [LogEntry] {
        removal.hidden.isEmpty ? entries : entries.filter { !removal.isHidden($0) }
    }

    private var waiting: [PendingOperation] {
        JournalStore.waiting(in: outbox.pending, farm: FarmPath.openSlug, listed: store.entries)
    }

    /// Every kept treatment, on any farm. One leaving the queue was
    /// delivered — a refusal stays — so the list is read again, and the
    /// server's row, with its document, takes its place.
    private var queuedTreatments: Set<String> {
        Set(outbox.pending.filter { $0.treatment != nil }.map(\.id))
    }

    var body: some View {
        RoutedStack {
            // БОРСА'S SHAPE, which the owner made canonical: the list is
            // the only thing in the stack, and the title is a real
            // navigation title rather than a block drawn inside the page.
            //
            // Two previous attempts put chrome above the list — first a
            // `safeAreaInset`, then a VStack — and both still dragged the
            // title on the pull. Борса has neither, and Борса is the one
            // screen whose refresh has ever behaved. So the chrome is gone
            // rather than rearranged for a third time.
            //
            // WHAT THIS COSTS: a large navigation title truncates at
            // accessibility text sizes and cannot be told not to, which is
            // why the in-content header existed — «Земеделски дневник»
            // rendered as «Земеделски…» at accessibility3. That was a real
            // finding and this overrides it knowingly, on the owner's
            // instruction, because a refresh gesture that misbehaves on
            // every screen costs more than a title that truncates on one
            // text size.
            content
                .background(Palette.Surface.page)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if let undoable = removal.undoable { undoBar(undoable) }
                        newEntryButton
                    }
                }
            .navigationTitle("Земеделски дневник")
            .appMenu()
            .toolbar {
                // Type, crop, block and period (#252). The state is the
                // icon's fill and the summary row above the entries; the
                // name stays «Филтри» either way, as on Борса.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        filtering = true
                    } label: {
                        Label("Филтри", systemImage: store.filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Филтри")
                    .accessibilityValue(store.filter.isActive ? "активни" : "")
                    .accessibilityInputLabels(A11y.Spoken.filters)
                }
                // The БАБХ ДНЕВНИК for a location and a period (#246) — the
                // web's «Дневник (PDF)», from this page. Not the bottom bar:
                // that is the action taken standing in a field; this one is
                // taken for the inspector, once a season.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportingRecord = true
                    } label: {
                        Label("Дневник (PDF)", systemImage: "doc.richtext")
                    }
                    .accessibilityLabel("Дневник (PDF)")
                    .accessibilityInputLabels(A11y.Spoken.farmRecord)
                }
            }
            // «Нов запис» is the two-step treatment record (#293). The saved
            // entry comes back from the server folded into one row, which
            // the phone cannot build itself, so the list is read again
            // behind the sheet. The ДНЕВНИК it may have downloaded goes when
            // the sheet does.
            .sheet(isPresented: $composing, onDismiss: FarmRecordAPI.removeGenerated) {
                TreatmentEntryFlow(recorder: LiveTreatmentRecorder()) {
                    Task { await store.load() }
                }
            }
            .sheet(isPresented: $exportingRecord, onDismiss: FarmRecordAPI.removeGenerated) {
                FarmRecordSheet()
            }
            .alert(TreatmentRemoval.confirmTitle, isPresented: $confirming, presenting: confirmingRemoval) { entry in
                Button(TreatmentRemoval.actionTitle, role: .destructive) { remove(entry) }
                    .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: { entry in
                Text(TreatmentRemoval.confirmMessage(entry))
            }
            .alert("Мероприятието не е изтрито", isPresented: $refused, presenting: removal.failure) { _ in
                Button("Затвори", role: .cancel) { removal.dismissFailure() }
            } message: { failure in
                Text(failure)
            }
            .onChange(of: removal.failure) { _, failure in
                refused = failure != nil
            }
            .sheet(isPresented: $filtering) {
                JournalFilterSheet(filter: store.filter, options: filterOptions) { chosen in
                    Task { await store.apply(chosen) }
                }
            }
            .task { if store.state.value == nil { await store.load() } }
            .onChange(of: queuedTreatments) { before, after in
                guard !before.subtracting(after).isEmpty else { return }
                Task { await store.load() }
            }
            .onChange(of: changes.revision) {
                Task { await store.load() }
            }
            .onChange(of: store.freshReads) {
                removal.listRead()
            }
        }
    }


    /// The primary action is a full-width target at the bottom of the screen,
    /// not a toolbar glyph. A gloved thumb reaches the bottom of a phone; the
    /// top-right corner is the hardest place on the device to hit one-handed,
    /// and this is the action an operator performs standing in a field.
    @ViewBuilder
    private var newEntryButton: some View {
        // Not to a role that cannot write — a reader or an auditor would be
        // refused after typing the entry (agrent-ios #312). Fails open while
        // nobody has said, as every write control does (`CurrentUser.mayWrite`).
        //
        // Whatever the LIST is doing (#384). It used to wait for the entries,
        // from when «Нов запис» could only post with signal. Since #324 it
        // queues offline, so a list that couldn't load (no signal and nothing
        // cached) is exactly when it must still be there.
        if people.user?.mayWrite ?? true {
            Button {
                composing = true
            } label: {
                Text("Нов запис").frame(maxWidth: .infinity, minHeight: 30)
            }
            .prominentButton()
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .solidBar(hairline: .top)
        }
    }

    /// The confirmed «Изтрий»: the row goes, the five seconds start, and it
    /// is said, with the way back.
    private func remove(_ entry: LogEntry) {
        removal.remove(entry, window: voiceOver || switchControl ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(TreatmentRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }

    /// What went, with «Отмени», for the five seconds before it is sent.
    /// Above «Нов запис», where the thumb that swiped already is.
    private func undoBar(_ undoable: TreatmentRemoval.Undoable) -> some View {
        // The sentence wraps rather than the button moving: at the largest
        // text sizes a product name runs to several lines, and «Отмени»
        // stays where the thumb found it.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // What went, then how much of the register that was, each on
            // its own line; VoiceOver reads them as one sentence.
            VStack(alignment: .leading, spacing: 2) {
                Text("Изтрито: \(undoable.title)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let extent = undoable.extent {
                    Text(extent)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TreatmentRemoval.removedText(undoable))
            Button(TreatmentRemoval.undoTitle) { removal.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }

    @ViewBuilder
    private var content: some View {
        // Read once per render: three cases and the section ask it.
        let waiting = waiting
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        // A filtered no-result is not an empty diary, and saying the wrong
        // one is a claim about the farm's records rather than about the
        // filter. The web's words (`journal.filteredEmpty*`).
        case .loaded(let entries, _) where visible(entries).isEmpty && waiting.isEmpty && store.filter.isActive:
            EmptyState(
                "Няма записи, отговарящи на филтрите",
                icon: "line.3.horizontal.decrease.circle",
                message: "Опитайте да разширите търсенето или да изчистите някой от активните филтри."
            ) {
                Button("Изчисти филтрите") { Task { await store.clearFilters() } }
            }

        case .loaded(let entries, _) where visible(entries).isEmpty && waiting.isEmpty:
            EmptyState(
                "Няма записи",
                icon: "book.closed",
                message: "Добавете първия запис в дневника."
            )

        case .loaded(let listed, _):
            let entries = visible(listed)
            List {
                waitingSection(waiting)
                // THE COUNT MOVED HERE from the in-content header, which
                // went with Борса's shape. It is a section header, so it
                // scrolls with the rows and cannot be dragged the way a
                // title block could.
                //
                // "Показани N" once there is more, because "N записа" is a
                // claim about the tenant's whole history that one page
                // cannot make. The old copy said exactly that and was wrong
                // for any farm past fifty entries.
                Section(titled: store.hasMore
                        ? "Показани " + Plural.bg(entries.count, "запис", "записа")
                        : Plural.bg(entries.count, "запис", "записа")) {
                if store.filter.isActive {
                    JournalFilterSummary(filter: store.filter) {
                        Task { await store.clearFilters() }
                    }
                    .pageRow()
                }
                let partial = JournalStore.partial(in: outbox.pending, farm: FarmPath.openSlug)
                ForEach(entries) { entry in
                    NavigationLink(value: AppRoute.journalEntry(entry)) {
                        JournalRow(entry: entry, partial: entry.treatment?.treatmentGroupId.flatMap { partial[$0] })
                    }
                    .pageRow()
                    // The WHOLE treatment, every parcel and block (#395).
                    // Not a full swipe: on a register, removing a record
                    // takes the tap on «Изтрий», then the question
                    // «Сигурни ли сте…?» (owner, 2026-10-26), and the bar
                    // below still offers «Отмени» for five seconds.
                    // VoiceOver lists it among the row's actions.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if TreatmentRemoval.offered(entry, to: people.user) {
                            Button(role: .destructive) {
                                confirmingRemoval = entry
                                confirming = true
                            } label: {
                                Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                            }
                            .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                        }
                    }
                }
                loadMoreRow
                    .pageRow()
                }
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    /// What has not reached the server yet, above what has: the person's
    /// own unsent work is the first thing they look for after saving with
    /// no signal (#324). Absent when nothing waits, which is almost always.
    @ViewBuilder
    private func waitingSection(_ waiting: [PendingOperation]) -> some View {
        if !waiting.isEmpty {
            Section(titled: "Още не са на сървъра") {
                ForEach(waiting) { item in
                    if let treatment = item.treatment {
                        QueuedTreatmentRow(item: item, treatment: treatment)
                            .pageRow()
                    }
                }
            }
        }
    }

    /// PARITY GAP 6, and the reason it is a row rather than nothing.
    ///
    /// The list was capped at 50 with no cursor, so a tenant past fifty
    /// entries saw a truncated history and NOTHING ON SCREEN SAID SO. That
    /// is the worst shape a limit can take: a short list and a complete
    /// list look identical, so the operator has no way to tell which they
    /// are looking at — on the register the ДНЕВНИК PDF is generated from.
    ///
    /// Explicit, not infinite scroll. Loading on scroll would fetch pages
    /// an operator did not ask for, on a connection this app assumes is
    /// bad, and would still say nothing about whether the end had been
    /// reached. A button that disappears when there is no more is itself
    /// the answer to "is this all of it".
    @ViewBuilder
    private var loadMoreRow: some View {
        if store.hasMore {
            VStack(alignment: .leading, spacing: 6) {
                if store.loadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Зареждане…").font(.footnote).foregroundStyle(Palette.secondaryText)
                    }
                } else {
                    Button("Покажи още") { Task { await store.loadMore() } }
                }
                if let error = store.loadMoreError {
                    // The pages already on screen are still good, so this
                    // is a note beside them rather than an error state that
                    // replaces them.
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One diary entry.
///
/// Sized for the actual reading conditions: outdoors, in sunlight, at arm's
/// length, with Dynamic Type possibly turned well up. The previous version
/// set the title at `.subheadline` and everything else at `.caption` — the
/// design review counted `.footnote` used ten times across the app and
/// `.body` not once, which is a desk application's type scale on a tool meant
/// to be used standing in a field.
///
/// So: `.headline` title, `.subheadline` supporting text, and the type as a
/// CHIP rather than one more grey word in a run of grey words — at a glance a
/// regulated input application is now distinguishable from an observation
/// without reading either.
struct JournalRow: View {
    let entry: LogEntry
    /// The phone's copy of this treatment, when the server's answer to it
    /// came back short (#326): the row says the rest is missing.
    var partial: PendingOperation.QueuedTreatment? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)

            // A folded treatment (agri-saas #1799) says how much it covered,
            // where, and when its crop may be harvested — the three facts a
            // register row is read for, and none of them in the entry's own
            // title, which names one parcel of many.
            if let treatment = entry.treatment, treatment.isTreatment {
                treatmentLines(treatment)
            }

            if let text = partial?.partialText {
                // Amber only once resending stops getting further: until
                // then the phone is still finishing it, which needs nobody.
                Label(text, systemImage: partial?.stalled == true ? "exclamationmark.triangle" : "tray.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(partial?.stalled == true ? Palette.warning : Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = entry.treatment?.unfinishedText {
                // Unfinished on the server and not on its way from this
                // phone: someone has to finish it or end it, on its screen.
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AdaptiveRow { chip; dateAndStatus }
        }
        .padding(.vertical, 6)
        // One stop per entry, spoken from the VALUES.
        //
        // `children: .combine` would read the rendered text, which includes
        // the `·` between date and status — "21 септември middle dot
        // Планирано". The separator is typography and has no business in the
        // audio channel, so the label is built from the fields instead. It
        // also lets the chip be spoken as what it MEANS ("Внасяне на
        // препарат") rather than as a decorated fragment, and lets the status
        // be named only when it is worth naming.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            entry.displayTitle,
            entry.type.label,
            entry.occurredAt.map(BgDate.full) ?? LogEntry.noDate,
            entry.status == .planned ? entry.status.label : nil,
        ] + Self.spokenTreatment(entry.treatment) + [partial?.partialText ?? entry.treatment?.unfinishedText]))
    }

    /// The treatment's facts in words — «декара», never the «дка» a screen
    /// shows, which VoiceOver spells out letter by letter (see `Area`).
    static func spokenTreatment(_ treatment: JournalTreatment?) -> [String?] {
        guard let treatment, treatment.isTreatment else { return [] }
        return [
            Plural.bg(treatment.parcelCount, "парцел", "парцела"),
            treatment.area?.spoken,
            treatment.blockNames.isEmpty ? nil : treatment.blockNames.joined(separator: ", "),
            treatment.earliestHarvest.map { "\(Self.harvestLabel) \(BgDate.full($0))" },
        ]
    }

    static let harvestLabel = "Най-ранно прибиране"

    private func treatmentLines(_ treatment: JournalTreatment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MetaRow {
                Text(Plural.bg(treatment.parcelCount, "парцел", "парцела"))
                if let area = treatment.area {
                    MetaSeparator()
                    Text(area.text)
                }
            }
            if !treatment.blockNames.isEmpty {
                Text(treatment.blockNames.joined(separator: ", "))
            }
            if let harvest = treatment.earliestHarvest {
                Text("\(Self.harvestLabel): \(BgDate.dayMonth(harvest))")
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chip: some View {
        CategoryChip(
            text: entry.type.label,
            foreground: entry.type.chipColors.foreground,
            background: entry.type.chipColors.background
        )
    }

    private var dateAndStatus: some View {
        // fixedSize on the vertical axis lets the date take the height it
        // needs rather than being compressed into a mid-word break.
        MetaRow {
            Text(entry.occurredAt.map(BgDate.dayMonth) ?? LogEntry.noDate)
            if entry.status == .planned {
                MetaSeparator()
                Text(entry.status.label)
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}
