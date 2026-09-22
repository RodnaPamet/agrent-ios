import SwiftUI

/// Members and the farm's identity block.
///
/// Reached from the app menu rather than a tab: five tab slots exist before
/// iOS collapses the rest into "More", and this is a monthly action while
/// Задачи is a daily one. Опрerator frequency decides the tab bar.
struct AdminView: View {
    @State private var store = AdminStore()
    @State private var revealEGN = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Админ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
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
                membersSection
                farmProfileSection
            }
            .refreshable { await store.load() }
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
            ForEach(store.grouped(all), id: \.0) { status, rows in
                Section(status.label) {
                    ForEach(rows) { MemberRow(member: $0) }
                }
            }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(revealEGN ? "ЕГН, показано" : "ЕГН, скрито")
            .accessibilityHint(revealEGN ? "Двоен допир, за да скриете" : "Двоен допир, за да покажете")
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
