import QuickLook
import SwiftUI

/// «Публичен профил»: the farm's public page as its administrators see and
/// edit it (P6.6; agrent-ios #323, owner 2026-10-15: "build now, behind the
/// flag").
///
/// ── The shape of `FarmProfileView` ──
///
/// What the page shows, read-only, with «Редактирай» opening a sheet that
/// saves. The sheet carries the unsaved-changes guard, so the page itself
/// has nothing to lose to a back swipe.
///
/// ── What it does and doesn't do ──
///
/// It edits the five fields, claims the web address, and for a published
/// page shares the link, opens the server's A6 card to print (P6.7) and
/// takes the page down. It does NOT publish. Publishing needs a recorded consent to a
/// versioned text, the owner chose the web's text for the phone, and the
/// web doesn't have one yet. The section says so instead of offering a
/// button that can only be refused (`FARM_BRAND_CONSENT_REQUIRED`).
///
/// ── Never cached ──
///
/// Admin data stays off disk (`ResponseCache` holds none), so the draft is
/// read on every open. With no signal the page says it couldn't load. An
/// old copy of a page someone may be editing elsewhere is no use here.
struct PublicProfileView: View {
    enum Phase: Equatable {
        case loading
        case failed(String)
        /// nil: the farm has never saved a draft.
        case ready(FarmBrandDraft?)
    }

    @State private var phase: Phase = .loading
    @State private var editing = false
    @State private var choosingAddress = false
    @State private var confirmingWithdraw = false
    @State private var withdrawing = false
    @State private var printingCard = false
    /// The A6 card while Quick Look shows it.
    @State private var card: URL?
    @State private var failure: String?
    /// What the last change did, said until the next one.
    @State private var note: String?

    static let title = "Публичен профил"

    private var draft: FarmBrandDraft? {
        if case .ready(let draft) = phase { return draft }
        return nil
    }

    var body: some View {
        PageForm {
            switch phase {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                Section {
                    Text(message).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
                    Button("Опитай пак") { Task { await load() } }
                        .accessibilityInputLabels(A11y.spokenNames("Опитай пак", "Retry"))
                }
            case .ready(let draft):
                ready(draft)
            }
        }
        .inlineTitle(Self.title)
        .toolbar {
            if case .ready = phase {
                ToolbarItem(placement: .primaryAction) {
                    Button("Редактирай") { editing = true }
                        .accessibilityInputLabels(A11y.spokenNames("Редактирай", "Edit"))
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $editing) {
            PublicProfileEditView(saved: draft) {
                note = Self.savedNote
                await load()
            }
        }
        .sheet(isPresented: $choosingAddress) {
            PublicAddressSheet(current: draft?.handle, published: draft?.published ?? false) { claim in
                note = Self.claimedNote(claim)
                await load()
            }
        }
        .quickLookPreview($card)
        // Removed when Quick Look closes (`FarmRecordAPI.removeGenerated`).
        .onChange(of: card) { _, now in
            if now == nil { FarmRecordAPI.removeGenerated() }
        }
        // Said, not only drawn: a refusal shows at the top of the page,
        // away from the button that was tapped.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private func ready(_ draft: FarmBrandDraft?) -> some View {
        if let note {
            Section {
                Label(note, systemImage: "checkmark.circle")
                    .foregroundStyle(Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let failure {
            Section {
                Text(failure).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
            }
        }

        Section {
            fact("Име", draft?.displayName)
            fact("Кратко описание", draft?.tagline)
            fact("За стопанството", draft?.about)
            fact("Област", draft?.oblast)
            fact("Култури", draft.map { $0.crops.joined(separator: ", ") })
        } header: {
            SectionHeader("Какво показва страницата")
        } footer: {
            SectionFooter(Self.about)
        }

        addressSection(draft)
        publicationSection(draft)
    }

    /// One fact, its label above it, and «—» for one not filled in, so the
    /// row still says what's missing.
    private func fact(_ label: String, _ value: String?) -> some View {
        let shown = value?.recorded
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(Palette.secondaryText)
            Text(shown ?? "—").foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([label, shown ?? Self.notFilled]))
    }

    // MARK: - Address

    private func addressSection(_ draft: FarmBrandDraft?) -> some View {
        Section {
            if let handle = draft?.handle {
                Text(PublicProfileLink.displayAddress(handle: handle))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Няма избран адрес").foregroundStyle(Palette.secondaryText)
            }
            Button(draft?.handle == nil ? "Избери адрес" : "Промени адреса") { choosingAddress = true }
                // The server keeps an address on the draft, so there has to
                // be one: the first save makes it.
                .disabled(draft == nil)
                .accessibilityInputLabels(A11y.spokenNames(
                    draft?.handle == nil ? "Избери адрес" : "Промени адреса", "Address"))
        } header: {
            SectionHeader("Адрес")
        } footer: {
            SectionFooter(draft == nil ? Self.addressAfterSave : Self.addressAbout)
        }
    }

    // MARK: - Publication

    @ViewBuilder
    private func publicationSection(_ draft: FarmBrandDraft?) -> some View {
        if let draft, draft.published, let handle = draft.handle, let url = PublicProfileLink.url(handle: handle) {
            Section {
                Label("Страницата е публикувана", systemImage: "globe")
                ShareLink(item: url, message: Text(draft.displayName ?? "")) {
                    Label("Сподели", systemImage: "square.and.arrow.up")
                }
                .accessibilityInputLabels(A11y.spokenNames("Сподели", "Share"))
                Button {
                    Task { await printCard(handle) }
                } label: {
                    if printingCard {
                        ProgressView().accessibilityLabel("Изготвяне на картата")
                    } else {
                        Label("Карта за печат (A6)", systemImage: "qrcode")
                    }
                }
                .disabled(printingCard)
                .accessibilityInputLabels(A11y.spokenNames("Карта за печат", "Карта", "Print card"))
                Link(destination: url) {
                    Label("Отвори страницата", systemImage: "safari")
                }
                .accessibilityInputLabels(A11y.spokenNames("Отвори страницата", "Open page"))
                Button(role: .destructive) {
                    confirmingWithdraw = true
                } label: {
                    if withdrawing {
                        ProgressView().accessibilityLabel("Спиране на публикуването")
                    } else {
                        Label("Спри публикуването", systemImage: "eye.slash")
                            .foregroundStyle(Palette.destructive)
                    }
                }
                .disabled(withdrawing)
                .accessibilityInputLabels(A11y.spokenNames("Спри публикуването", "Unpublish"))
                .confirmationDialog("Спиране на публикуването", isPresented: $confirmingWithdraw,
                                    titleVisibility: .visible) {
                    Button("Спри публикуването", role: .destructive) { Task { await withdraw() } }
                        .accessibilityInputLabels(A11y.spokenNames("Спри публикуването", "Unpublish"))
                    Button("Отказ", role: .cancel) {}
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                } message: {
                    Text(Self.withdrawMessage(PublicProfileLink.displayAddress(handle: handle)))
                }
            } header: {
                SectionHeader("Публикуване")
            } footer: {
                SectionFooter(Self.cardAbout)
            }
        } else {
            Section {
                Text("Страницата не е публикувана.")
            } header: {
                SectionHeader("Публикуване")
            } footer: {
                SectionFooter(Self.publishLater)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            phase = .ready(try await FarmBrandAPI.draft())
        } catch {
            phase = .failed(UserMessage.text(for: error))
        }
    }

    private func withdraw() async {
        withdrawing = true
        failure = nil
        defer { withdrawing = false }
        do {
            try await FarmBrandAPI.withdraw()
            note = Self.withdrawnNote
            await load()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    /// The card is the server's (agri-saas #1910), so the QR on it is the
    /// one encoder's: drawing a second QR here would make a different code
    /// for the same address, and only the screen's could ever be redrawn.
    private func printCard(_ handle: String) async {
        printingCard = true
        failure = nil
        defer { printingCard = false }
        do {
            card = try await FarmBrandAPI.shareCard(handle: handle)
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    // MARK: - Words

    static let about = "Страница на стопанството, която всеки може да отвори, без да има профил в Agrent. "
        + "Показва само попълненото тук."
    static let notFilled = "не е попълнено"
    static let addressAbout = "Връзката, на която се отваря страницата. Един адрес е на едно стопанство."
    static let addressAfterSave = "Адрес може да се избере, след като профилът бъде запазен."
    static let publishLater = "Публикуването ще стане възможно, когато е готов текстът на съгласието, "
        + "което се дава преди публикуване."
    static let cardAbout = "Картата за печат е PDF с името на стопанството, адреса на страницата "
        + "и QR код към нея, за раздаване на пазара или в стопанството."
    static let savedNote = "Профилът е запазен."
    static let withdrawnNote = "Страницата вече не е публикувана."

    nonisolated static func claimedNote(_ claim: HandleClaim) -> String {
        let address = PublicProfileLink.displayAddress(handle: claim.handle)
        return claim.normalised ? "Адресът е записан като \(address)." : "Адресът е \(address)."
    }

    nonisolated static func withdrawMessage(_ address: String) -> String {
        "Страницата на \(address) спира да се отваря веднага. Профилът остава запазен."
    }
}
