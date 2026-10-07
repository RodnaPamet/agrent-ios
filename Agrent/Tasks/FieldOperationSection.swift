import SwiftUI

/// A field operation's parcel lines on the task screen, each with the web's
/// three buttons — «Готово», «Пропусни», «Отвори отново» (agrent-ios#138).
///
/// ── Where, and what is not here ──
///
/// On the task detail, as on the web (`FarmTaskDetailClient` renders
/// `FieldOperationPanel` for a FIELD_OPERATION task). The panel's map and its
/// «Необходимо: …» amounts are NOT ported — PARITY.md says why — so a line is
/// its parcel, its product and dose, its area, its status and its buttons.
///
/// ── What it shows that the server does not ──
///
/// This person's marks still on the phone. A line with one waiting shows the
/// status it will have, with «Още не е на сървъра» beside it; a line whose
/// queued mark met somebody else's change shows the choice between theirs and
/// the server's; a refused mark stays visible as the record of the refusal.
/// The outbox is observed, so the drain sending a mark — or parking one —
/// changes the line and re-reads the job without anyone touching the screen.
struct FieldOperationSection: View {
    let store: FieldOperationStore

    @State private var outbox = OutboxStore.shared
    @State private var people = CurrentUserStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FieldOperationText.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The person's own tap, and nothing else — see `FieldOperationStore`.
        .writeFeedback(store.feedback)
        // Two tasks, not one: `/me` can wait out a request timeout with no
        // signal, and the lines must not wait behind it.
        .task { if store.state.value == nil { await store.load() } }
        .task { _ = await people.load() }
        // The drain sent or parked one of this job's marks: the server's line
        // has moved, so the job is re-read as after any write.
        .onChange(of: FieldOperationRules.queued(outbox.pending, taskID: store.taskID)) { old, new in
            if FieldOperationRules.reloadNeeded(from: old, to: new) {
                Task { await store.loadAfterWrite() }
            }
        }
        // The sentence under the line is the answer to a tap; VoiceOver's
        // focus is still on the button that made it, so it is said aloud.
        .onChange(of: store.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text).post() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            // The task above loaded and this did not — say so here, under its
            // own heading, with its own way out, and leave the task usable.
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Опитай пак") { Task { await store.load() } }
                    .buttonStyle(MarkButtonStyle(prominent: false))
            }

        case .loaded(let detail, _):
            lines(detail)
        }
    }

    @ViewBuilder
    private func lines(_ detail: FieldOperationDetail) -> some View {
        let rows = FieldOperationRules.rows(
            lines: detail.lines, pending: outbox.pending, taskID: store.taskID)
        let me = people.user
        let mayMark = FieldOperationRules.mayMark(me: me, assigneeUserID: detail.task.assigneeUserId)
        let progress = FieldOperationRules.progress(rows)

        Text(FieldOperationText.progress(done: progress.done, total: progress.total))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        if me == nil {
            RefusalNote(text: FieldOperationText.waitingForUser, icon: "person.crop.circle")
        } else if !mayMark {
            // An absent button says nothing; the reason is said instead.
            RefusalNote(text: FieldOperationText.notPermitted, icon: "hand.raised")
        }
        ForEach(rows) { row in
            LineRow(
                row: row,
                actions: FieldOperationRules.actions(for: row, mayMark: mayMark),
                busy: store.busyLineID == row.id,
                anotherBusy: store.busyLineID != nil && store.busyLineID != row.id,
                notice: FieldOperationRules.visibleNotice(store.notice, for: row),
                mark: { target in Task { await store.mark(row.line, as: target, by: me) } },
                keepMine: { id in Task { await outbox.keepMine(id) } },
                takeServer: { id in Task { await outbox.takeServer(id) } }
            )
        }
    }
}

/// One line: what it is, what it shows, and what can be done to it.
private struct LineRow: View {
    let row: LineState
    let actions: [OperationLineStatus]
    let busy: Bool
    let anotherBusy: Bool
    let notice: FieldOperationStore.Notice?
    let mark: (OperationLineStatus) -> Void
    let keepMine: (String) -> Void
    let takeServer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            facts
            if let item = row.conflict, let conflict = item.conflict {
                ConflictCard(item: item, conflict: conflict, keepMine: keepMine, takeServer: takeServer)
            }
            ForEach(row.refused) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Label(FieldOperationText.refusedQueued(item.lineMark?.lineStatus ?? .unknown),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.warning)
                    if let reason = item.lastError {
                        Text(reason).foregroundStyle(Palette.secondaryText)
                    }
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
            controls
            if let notice {
                Text(notice.text)
                    .font(.footnote)
                    .foregroundStyle(notice.kind.colour)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One stop for VoiceOver, spoken from the values — the `·` between them
    /// is typography and the unit symbols are letters, so the sentence uses
    /// the unit's NAME and the area's spoken form instead.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow {
                Text(row.line.parcel.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                CategoryChip(
                    text: row.shown.label,
                    foreground: row.shown.chipColors.foreground,
                    background: row.shown.chipColors.background
                )
            }
            MetaRow {
                Text(row.line.product.name)
                MetaSeparator()
                Text("\(row.line.doseText) \(row.line.doseUnit.symbol)")
                if let area = row.line.area {
                    MetaSeparator()
                    Text(area.text)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            if row.waiting != nil {
                Label(FieldOperationText.notOnServer, systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            row.line.parcel.name,
            row.shown.label,
            row.waiting != nil ? FieldOperationText.notOnServer : nil,
            row.line.product.name,
            "\(row.line.doseText) \(row.line.doseUnit.name ?? row.line.doseUnit.symbol)",
            row.line.area?.spoken,
        ]))
    }

    @ViewBuilder
    private var controls: some View {
        if busy {
            ProgressView()
        } else if !actions.isEmpty {
            AdaptiveRow(spacing: 12) {
                ForEach(actions, id: \.self) { target in
                    Button(FieldOperationText.verb(target)) { mark(target) }
                        .buttonStyle(MarkButtonStyle(prominent: target == .done))
                        // Each line has its own «Готово», so the parcel is
                        // in the name VoiceOver reads; Voice Control still
                        // answers to the bare verb, in either language.
                        .accessibilityLabel("\(FieldOperationText.verb(target)), \(row.line.parcel.name)")
                        .accessibilityInputLabels(FieldOperationText.spoken(target))
                        .disabled(anotherBusy)
                }
            }
        }
    }

}

/// A queued mark that met a newer change — the web's resolver, in its own
/// words. «Запази моята» only when the server reported the version to re-send
/// at; without it the overwrite could not be guarded.
private struct ConflictCard: View {
    let item: PendingOperation
    let conflict: PendingOperation.Conflict
    let keepMine: (String) -> Void
    let takeServer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(FieldOperationText.conflictTitle, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.warning)
            Text(FieldOperationText.conflictDescription(item.parcelSummary))
                .font(.footnote)
            if conflict.currentVersion == nil {
                Text(FieldOperationText.keepMineUnavailable)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
            AdaptiveRow(spacing: 12) {
                if conflict.currentVersion != nil {
                    Button(FieldOperationText.keepMine) { keepMine(item.id) }
                        .buttonStyle(MarkButtonStyle(prominent: true))
                        .accessibilityInputLabels(A11y.spokenNames(FieldOperationText.keepMine, "Keep mine"))
                }
                Button(FieldOperationText.takeServer) { takeServer(item.id) }
                    .buttonStyle(MarkButtonStyle(prominent: false))
                    .accessibilityInputLabels(A11y.spokenNames(FieldOperationText.takeServer, "Use server"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button big enough for a gloved thumb, in the two measured pairs.
///
/// Prominent: `onAccent` on `accent` (8.45 / 5.21 / 5.21, `PaletteTokenTests`).
/// Outlined: `accent` text and edge on the line's `Surface.card` (6.59 / 5.09
/// / 5.49). Not `.bordered`: its tinted fill is a pair nobody has measured.
/// 50 points, the height of the system's large prominent button, so the two
/// sit level when they share a row.
private struct MarkButtonStyle: ButtonStyle {
    let prominent: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? Palette.onAccent : Palette.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minHeight: 50)
            .background {
                if prominent {
                    Capsule().fill(Palette.accent)
                } else {
                    Capsule().strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

private extension FieldOperationStore.Notice.Kind {
    /// Kept and cancelled are information; a conflict is the caveat; a
    /// refusal the error.
    var colour: Color {
        switch self {
        case .kept, .cancelled: Palette.secondaryText
        case .conflict: Palette.warning
        case .refused: Palette.error
        }
    }
}

extension OperationLineStatus {
    /// The web's tones (`ag-status.tsx`, `operationParcel`): DONE is the
    /// success badge, everything else neutral. The pairs are measured.
    var chipColors: (foreground: Color, background: Color) {
        switch self {
        case .done: (Palette.Chip.successText, Palette.Chip.successFill)
        case .pending, .skipped, .unknown: (Palette.Chip.neutralText, Palette.Chip.neutralFill)
        }
    }
}
