import SwiftUI

/// Members and the farm's identity block.
///
/// Reached from the app menu rather than a tab: five tab slots exist before
/// iOS collapses the rest into "More", and this is a monthly action while
/// Задачи is a daily one. Опрerator frequency decides the tab bar.
struct AdminView: View {
    @State private var store = AdminStore()
    @State private var revealEGN = false
    @State private var inviting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Админ")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                    }
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
                .task { await store.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.access {
        case .forbidden:
            // A REAL state, not an error. The web has viewer accounts, and
            // these routes use `requirePermission('admin.members')` — so a
            // READER gets a 403 by design. An empty list would say "this
            // farm has no members", which is a false statement about the
            // farm rather than a true one about the reader.
            EmptyState(
                "Нямате достъп до този раздел",
                icon: "lock",
                message: "Управлението на достъпа е достъпно само за администратори на стопанството."
            )

        case .allowed:
            List {
                // The bottom-row editor, moved off every screen's toolbar
                // and into the one place that holds settings.
                Section("Приложение") { TabCustomiserRow() }.pageRow()
                membersSection.pageRow()
                farmProfileSection.pageRow()
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
                Text("Няма членове.").font(.footnote).foregroundStyle(.secondary)
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
                    Text(writeUnknown).font(.footnote).foregroundStyle(.secondary)
                    Text("Връзката прекъсна. Проверете статуса в списъка по-долу — той е меродавен.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                            .swipeActions(edge: .trailing) { actions(for: member) }
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
            if !store.isLastOwner(member) {
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

    // MARK: - Farm profile

    @ViewBuilder
    private var farmProfileSection: some View {
        switch store.profile {
        case .loading:
            Section("Стопанство") { ProgressView() }

        case .failed(let message):
            Section("Стопанство") {
                Text(message).font(.footnote).foregroundStyle(Palette.error)
            }

        case .loaded(let profile, _) where profile.isEmpty:
            Section("Стопанство") {
                Text("Данните за стопанството още не са попълнени.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .loaded(let profile, _):
            Section("Стопанство") {
                field("Производител", profile.producerName)
                field("ЕИК", profile.eik)
                egnField(profile.egn)
                field("Адрес", profile.address)
                field("Населено място", profile.settlement)
                field("Община", profile.municipality)
                field("Място на регистрация", profile.registrationPlace)
                field("ЕКАТТЕ", profile.registrationEkatte)
                field("ОДБХ", profile.odbhCity)
                field("Областна дирекция", profile.agricultureDirectorateCity)
            }
        }
    }

    /// An EGN is a national identity number, and this is the one field where
    /// the mobile context genuinely differs from the web's.
    ///
    /// The web renders it plainly, which is right on a laptop. A phone is
    /// read over shoulders in a co-op office or a queue, so it is masked
    /// with an explicit reveal — still shown, still one tap, and not sitting
    /// on screen for anyone standing behind the operator.
    ///
    /// Masked by DIGIT COUNT, not by a fixed run of dots: showing the wrong
    /// length would make a wrong value look plausible when revealed.
    @ViewBuilder
    private func egnField(_ egn: String?) -> some View {
        if let egn, !egn.isEmpty {
            LabeledContent("ЕГН") {
                HStack(spacing: 10) {
                    Text(revealEGN ? egn : String(repeating: "•", count: egn.count))
                        .font(.body.monospacedDigit())
                    Button(revealEGN ? "Скрий" : "Покажи") { revealEGN.toggle() }
                        .font(.footnote)
                }
            }
            // The number itself is never in the label. VoiceOver reads
            // aloud, and a national ID spoken in a shared space is the
            // same exposure this masking exists to avoid.
            //
            // ── AND `children: .ignore` SWALLOWED THE ONLY CONTROL ──
            //
            // Collapsing the row to one element discarded the «Покажи»
            // Button with everything else, so the hint promised a double tap
            // that did nothing: the element carried no action. The ЕГН could
            // not be revealed by VoiceOver at all, the button was absent from
            // the Switch Control and Full Keyboard focus order, and Voice
            // Control had no element named «Покажи» to act on. Reachable only
            // by a finger on the exact glyphs.
            //
            // Found by two independent lenses of an accessibility audit, which
            // is the corroboration that made it worth trusting: the privacy
            // instinct was right and the side effect was invisible from
            // either one alone.
            //
            // The action restores it without putting the digits back into
            // speech — the label still says only whether it is shown.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(revealEGN ? "ЕГН, показано" : "ЕГН, скрито")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { revealEGN.toggle() }
            // What a Voice Control user SEES on the button, so «Покажи» works
            // as spoken. The visible word is not in the accessibility label
            // and would otherwise match nothing.
            .accessibilityInputLabels(
                revealEGN ? ["Скрий", "ЕГН"] : ["Покажи", "ЕГН"])
            .accessibilityHint(revealEGN ? "Скрива номера" : "Показва номера")
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            LabeledContent(label) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MemberRow: View {
    let member: Membership

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(member.user.displayName ?? "—")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { roleChip; meta }
                VStack(alignment: .leading, spacing: 6) { roleChip; meta }
            }
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
        HStack(spacing: 6) {
            if let email = member.user.email, !email.isEmpty {
                Text(email).lineLimit(1).truncationMode(.middle)
            }
            if let sessionText {
                if member.user.email != nil { Text("·").foregroundStyle(.secondary) }
                Text(sessionText)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .inlineTitle("Покани член")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Изпрати") { Task { await submit() } }.disabled(!canSend)
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
