import SwiftUI

/// «Потребители» — the farm's members, on their own page.
///
/// ── MOVED, NOT REDESIGNED (owner, 2026-10-01) ──
///
/// This was the bulk of Админ: the root screen opened onto a staff directory
/// with the farm's identity block under it. The owner asked for the members
/// to get their own page behind one row, so Админ reads as a short list of
/// the things it manages. Everything below — the invite, the four status
/// sections, the swipe actions with full swipe OFF, the last-owner
/// explanation, the unknown-outcome note — is the code that was on Админ,
/// moved verbatim; only the container changed.
///
/// THE STORE IS ADMIN'S, passed in rather than owned. Админ shows the member
/// COUNT on its row, so both screens read one list; a store per page would
/// load it twice and let the count and the list disagree after a
/// deactivation.
struct MembersView: View {
    let store: AdminStore
    @State private var inviting = false

    var body: some View {
        content
            .inlineTitle("Потребители")
            .toolbar {
                if store.access == .allowed {
                    ToolbarItem(placement: .primaryAction) {
                        Button { inviting = true } label: {
                            Label("Покани", systemImage: "person.badge.plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $inviting) {
                InviteMemberView { email, role in
                    try await store.invite(email: email, role: role)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.access {
        case .forbidden:
            // Reachable only if access flips WHILE this page is open — a
            // pull-to-refresh after the reader's role was lowered. Админ hides
            // the row otherwise. Same sentence as Админ's, for the same reason:
            // an empty list would say "this farm has no members".
            EmptyState(
                "Нямате достъп до този раздел",
                icon: "lock",
                message: "Управлението на достъпа е достъпно само за администратори на стопанството."
            )

        case .allowed:
            List {
                membersSection.pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .pageBackground()
        }
    }

    // MARK: - Members

    @ViewBuilder
    private var membersSection: some View {
        switch store.members {
        case .loading:
            Section("Достъп") { ProgressView() }

        case .failed(let message):
            Section("Достъп") {
                ErrorState(message: message) { await store.load() }
            }

        case .loaded(let all, _) where all.isEmpty:
            Section("Достъп") {
                Text("Няма членове.").font(.footnote).foregroundStyle(Palette.secondaryText)
            }

        case .loaded(let all, _):
            if let writeUnknown = store.writeUnknown {
                Section {
                    // Not "it failed". The lookup filters ACTIVE, so a
                    // replay of a deactivation that already landed 404s —
                    // after a timeout the app cannot tell which happened,
                    // and the list below is the authority.
                    Label("Неясен резултат", systemImage: "questionmark.circle")
                        .foregroundStyle(Palette.error)
                    Text(writeUnknown).font(.footnote).foregroundStyle(Palette.secondaryText)
                    Text("Връзката прекъсна. Проверете статуса в списъка по-долу — той е меродавен.")
                        .font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            }
            if let writeError = store.writeError {
                Section {
                    Text(writeError).font(.footnote).foregroundStyle(Palette.error)
                }
            }
            ForEach(store.grouped(all), id: \.0) { status, rows in
                Section(status.label) {
                    ForEach(rows) { member in
                        MemberRow(member: member)
                            // FULL SWIPE OFF, which is the owner's ruling and
                            // closes a real hole.
                            //
                            // `allowsFullSwipe` defaults to TRUE, so a
                            // brisk swipe across a row fired the first
                            // destructive action directly — deactivating a
                            // member, removing their access to the farm, with
                            // no tap and no confirmation.
                            //
                            // The comment below reasons carefully about a TAP
                            // ("a button on every row invites a tap that was
                            // not meant") and nobody considered the gesture
                            // that reveals it. Same shape as the rest of this
                            // week: the care went into the case somebody
                            // pictured.
                            //
                            // Found by writing a UI test that swipes this row,
                            // and realising the test itself would have
                            // deactivated somebody real.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                actions(for: member)
                            }
                    }
                }
            }
        }
    }

    /// Deactivate and reactivate, as swipe actions rather than buttons in
    /// the row: this is a rare, consequential action on a screen that is
    /// mostly read, and a button on every row invites a tap that was not
    /// meant.
    ///
    /// The control is ABSENT on the last active owner rather than present
    /// and refused. The server counts them live and a database trigger
    /// backs it; counting here too means an admin never taps a thing that
    /// cannot work.
    @ViewBuilder
    private func actions(for member: Membership) -> some View {
        if store.busy.contains(member.id) {
            EmptyView()
        } else if member.status == .active {
            if store.isLastOwner(member) {
                // agrent-ios#99 — SAY WHY, RATHER THAN SPRINGING BACK SILENTLY.
                //
                // The destructive action stays ABSENT for the last active
                // owner: the server counts them live with a database trigger
                // behind it, and an action that cannot work should not be
                // offered. That reasoning is sound for a TAP and leaves a
                // swipe with nothing at all — the row bounces back, which is
                // indistinguishable from a swipe that did not register, so the
                // admin swipes again harder.
                //
                // NOT A BUTTON. A `Label` in a swipe slot, so the guard is not
                // weakened by making the refusal look actionable, and VoiceOver
                // has something to announce where there was silence.
                //
                // A DISABLED BUTTON, AND NOT BY PREFERENCE. The owner asked
                // for something that is NOT a button, and SwiftUI does not
                // offer one here.
                //
                // Measured rather than read, by photographing real swipes on
                // this screen:
                //
                //     a bare `Label` in the slot      renders NOTHING
                //     a disabled `Button`             renders
                //     a real Button (the control)     renders «Деактивирай»
                //
                // The control is what makes the first line mean anything. An
                // earlier in-process probe reached the opposite conclusion —
                // or rather reached no conclusion and read as one — because
                // its known-good Button ALSO came back empty, so its empty
                // results were evidence of nothing.
                //
                // THE COST, since it is a real one: VoiceOver announces this
                // as a dimmed button rather than as text. A farmer hears
                // something that sounds actionable and is not. That is worse
                // than plain text and better than the silence it replaces,
                // where a swipe sprang back with no explanation and the admin
                // swiped again harder.
                //
                // The spoken label carries the whole sentence; the visible one
                // is short because a swipe slot is narrow.
                Button {} label: {
                    Label("Последният собственик", systemImage: "lock")
                }
                .disabled(true)
                .tint(Color(.systemGray3))
                .accessibilityLabel("Последният собственик не може да се деактивира")
            } else {
                Button(role: .destructive) {
                    Task { await store.setActive(member, active: false) }
                } label: {
                    Label("Деактивирай", systemImage: "person.slash")
                }
            }
        } else if member.status == .deactivated {
            Button {
                Task { await store.setActive(member, active: true) }
            } label: {
                Label("Активирай", systemImage: "person.badge.clock")
            }
            .tint(Palette.accent)
        }
    }
}

struct MemberRow: View {
    let member: Membership

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(member.user.displayName ?? "—")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            AdaptiveRow { roleChip; meta }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([
            member.user.displayName,
            member.role.label,
            member.status == .active ? nil : member.status.label,
            sessionText,
            member.invitedBy?.name.map { "поканен от \($0)" },
        ]))
    }

    private var roleChip: some View {
        CategoryChip(
            text: member.role == .unknown ? member.role.rawValue : member.role.label,
            foreground: Palette.Chip.inputText,
            background: Palette.Chip.inputFill
        )
    }

    /// "is this account actually being used" is the question behind most
    /// deactivations, and the session count is the only thing on screen
    /// that answers it.
    private var sessionText: String? {
        guard let count = member.activeSessionCount, count > 0 else { return nil }
        return Plural.bg(count, "активна сесия", "активни сесии")
    }

    @ViewBuilder
    private var meta: some View {
        MetaRow {
            if let email = member.user.email, !email.isEmpty {
                // Middle truncation keeps the domain visible, which is the
                // half that identifies the person when a list is all one
                // farm's staff. At the accessibility sizes there is no half
                // left to keep — "и…bg" identifies nobody — so it wraps.
                Text(email)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
            }
            if let sessionText {
                if member.user.email != nil { MetaSeparator() }
                Text(sessionText)
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Invite somebody to the farm.
///
/// ── This one MAY be retried, unlike every other write in the app ──
///
/// There is a `@@unique([tenantId, email])` and the usecase writes
/// through it, so re-inviting an address with a pending invite UPSERTS
/// rather than creating a second row. A replay therefore produces one
/// invitation and one extra email — embarrassing, not harmful.
///
/// That is the opposite trade from the cost form and the listing form,
/// where a duplicate is a permanent wrong row. Here, refusing to retry
/// costs more than it saves, so a failure offers "Опитай пак" rather
/// than a warning about unknown outcomes.
private struct InviteMemberView: View {
    let send: (String, MembershipRole) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role: MembershipRole = .reader
    @State private var sending = false
    @State private var failure: String?

    /// Deliberately not a full address validator. The server validates,
    /// and a client-side regex that rejects a legitimate address is worse
    /// than one round trip — this only catches the empty and obviously
    /// unfinished cases so the button is not live before there is
    /// anything to send.
    private var canSend: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !sending && trimmed.contains("@") && !trimmed.hasSuffix("@")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Имейл") {
                    TextField("name@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Роля") {
                    Picker("Роля", selection: $role) {
                        // `unknown` is this client's sentinel for a role
                        // the server added and this build has not heard
                        // of. It can arrive; it must never be offered.
                        ForEach(MembershipRole.allCases.filter { $0 != .unknown }, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(Palette.error)
                        Text("Поканата може да се изпрати отново безопасно — повторното изпращане не създава втора покана.")
                            .font(.footnote).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            .inlineTitle("Покани член")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(sending)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Изпрати") { Task { await submit() } }
                            .disabled(!canSend)
                            .accessibilityInputLabels(A11y.Spoken.send)
                    }
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func submit() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await send(email.trimmingCharacters(in: .whitespacesAndNewlines), role)
            dismiss()
        } catch {
            // Stays open. A refused write whose message has gone reads as
            // a write that worked — #921, in a different form.
            failure = UserMessage.text(for: error)
        }
    }
}
