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
/// It edits the five fields, claims the web address, publishes, and for a
/// published page shares the link, opens the server's A6 card to print
/// (P6.7) and takes the page down. Publishing asks for consent to the web's
/// text first, unless the farm has agreed to that version already
/// (`PublishConsentSheet`). Taking the page down never asks.
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
    @State private var publishing = false
    @State private var askingConsent = false
    @State private var savingVisibility = false
    @Environment(\.dynamicTypeSize) private var typeSize
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
        .sheet(isPresented: $askingConsent) {
            PublishConsentSheet(stale: PublishingConsent.isStale(draft)) { published in
                if published { note = Self.publishedNote }
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
            fact(HideableField.tagline.label, draft?.tagline, hidden: draft?.hidden.contains(.tagline) == true)
            fact(HideableField.about.label, draft?.about, hidden: draft?.hidden.contains(.about) == true)
            fact(HideableField.oblast.label, draft?.oblast, hidden: draft?.hidden.contains(.oblast) == true)
            fact(HideableField.crops.label, draft.map { $0.crops.joined(separator: ", ") },
                 hidden: draft?.hidden.contains(.crops) == true)
        } header: {
            SectionHeader("Какво показва страницата")
        } footer: {
            SectionFooter(Self.about)
        }

        if let draft { visibilitySection(draft) }
        addressSection(draft)
        publicationSection(draft)
    }

    /// One fact, its label above it, and «—» for one not filled in, so the
    /// row still says what's missing. A hidden one says so under its text:
    /// the section claims to show what the page shows, and the page leaves
    /// it out.
    private func fact(_ label: String, _ value: String?, hidden: Bool = false) -> some View {
        let shown = value?.recorded
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(Palette.secondaryText)
            Text(shown ?? "—").foregroundStyle(hidden ? Palette.secondaryText : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if hidden {
                Label(Self.hiddenNote, systemImage: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.factSentence(label, shown, hidden: hidden))
    }

    // MARK: - Visibility

    /// «Показва се публично», a switch per field that can be withheld, ON
    /// meaning visible, as on the web (agri-saas #1933). Each saves at once
    /// and sends only its own flag. Shown once there's a draft: before that
    /// there's nothing stored to withhold.
    private func visibilitySection(_ draft: FarmBrandDraft) -> some View {
        Section {
            ForEach(HideableField.allCases, id: \.self) { field in
                // Soft hyphens: beside its switch at AX5 the label broke
                // «стопанст / вото». VoiceOver hears the plain words.
                Toggle(isOn: shownBinding(field, in: draft)) {
                    Text(SoftHyphens.display(field.label))
                }
                .accessibilityLabel(field.label)
                .disabled(savingVisibility)
                    .accessibilityInputLabels(A11y.spokenNames(field.label))
            }
        } header: {
            SectionHeader("Показва се публично")
        } footer: {
            SectionFooter(Self.visibilityAbout)
        }
    }

    /// The switch reads the draft and writes through `setShown`. The draft
    /// changes at once, so the switch doesn't spring back while the server
    /// answers, and is read again either way.
    private func shownBinding(_ field: HideableField, in draft: FarmBrandDraft) -> Binding<Bool> {
        Binding(
            get: { !draft.hidden.contains(field) },
            set: { shown in Task { await setShown(field, shown) } }
        )
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
                Label(SoftHyphens.display(Self.publishedState), systemImage: "globe")
                    .accessibilityLabel(Self.publishedState)
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
                Button {
                    startPublishing()
                } label: {
                    if publishing {
                        ProgressView().accessibilityLabel("Публикуване")
                    } else if typeSize.isAccessibilitySize {
                        // One long word: beside the globe at AX5 it broke
                        // «Публикува / й».
                        Text("Публикувай")
                    } else {
                        Label("Публикувай", systemImage: "globe")
                    }
                }
                .disabled(Self.missingForPublishing(draft) != nil || publishing)
                .accessibilityInputLabels(A11y.spokenNames("Публикувай", "Publish"))
            } header: {
                SectionHeader("Публикуване")
            } footer: {
                SectionFooter(Self.publishingFooter(draft))
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

    private func setShown(_ field: HideableField, _ shown: Bool) async {
        guard !savingVisibility, case .ready(var current?) = phase else { return }
        savingVisibility = true
        failure = nil
        defer { savingVisibility = false }
        if shown { current.hidden.remove(field) } else { current.hidden.insert(field) }
        phase = .ready(current)
        do {
            try await FarmBrandAPI.setShown(field, shown)
        } catch {
            failure = UserMessage.text(for: error)
        }
        await load()
    }

    /// Straight to the server when the farm agreed to this text already, as
    /// the web does. Otherwise the consent is asked for first.
    private func startPublishing() {
        guard PublishingConsent.isCurrent(draft) else {
            askingConsent = true
            return
        }
        Task { await publish() }
    }

    private func publish() async {
        publishing = true
        failure = nil
        defer { publishing = false }
        do {
            try await FarmBrandAPI.publish()
            note = Self.publishedNote
        } catch {
            failure = UserMessage.text(for: error)
        }
        // Either way: a refusal can mean the draft read here was out of date
        // (`FARM_BRAND_CONSENT_REQUIRED`), and the next tap must see the
        // server's record to ask for consent.
        await load()
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
    nonisolated static let notFilled = "не е попълнено"
    static let hiddenNote = "Не се показва публично."
    static let visibilityAbout = "Изключеното поле не се показва на страницата, но текстът му остава записан "
        + "и се връща, щом го включите отново."

    /// What VoiceOver hears for a fact: its label, its value or that it's
    /// empty, and that the page leaves it out.
    nonisolated static func factSentence(_ label: String, _ value: String?, hidden: Bool) -> String {
        A11y.sentence([label, value ?? notFilled] + (hidden ? ["не се показва публично"] : []))
    }
    static let addressAbout = "Връзката, на която се отваря страницата. Един адрес е на едно стопанство."
    static let addressAfterSave = "Адрес може да се избере, след като профилът бъде запазен."
    static let publishedNote = "Страницата е публикувана."
    static let publishedState = "Страницата е публикувана"
    static let cardAbout = "Картата за печат е PDF с името на стопанството, адреса на страницата "
        + "и QR код към нея, за раздаване на пазара или в стопанството."
    static let savedNote = "Профилът е запазен."
    static let withdrawnNote = "Страницата вече не е публикувана."

    /// What the server would refuse publishing for, said before the tap
    /// (`FARM_BRAND_HANDLE_REQUIRED`, `FARM_BRAND_DISPLAY_NAME_REQUIRED`); nil
    /// when nothing is missing. In the server's order: a draft, an address,
    /// a name.
    nonisolated static func missingForPublishing(_ draft: FarmBrandDraft?) -> String? {
        guard let draft else { return "Публикуването става възможно, след като профилът бъде запазен." }
        if draft.handle?.recorded == nil { return "Преди публикуване изберете адрес." }
        if draft.displayName?.recorded == nil { return "Преди публикуване попълнете името." }
        return nil
    }

    /// Under «Публикувай»: what's missing, else when the farm agreed to this
    /// text, else that the text comes first.
    nonisolated static func publishingFooter(_ draft: FarmBrandDraft?) -> String {
        if let missing = missingForPublishing(draft) { return missing }
        if PublishingConsent.isCurrent(draft), let at = draft?.consentedAt {
            return PublishingConsent.recorded(at)
        }
        return "Преди страницата да стане публична, ще бъде показан текстът на съгласието."
    }

    nonisolated static func claimedNote(_ claim: HandleClaim) -> String {
        let address = PublicProfileLink.displayAddress(handle: claim.handle)
        return claim.normalised ? "Адресът е записан като \(address)." : "Адресът е \(address)."
    }

    nonisolated static func withdrawMessage(_ address: String) -> String {
        "Страницата на \(address) спира да се отваря веднага. Профилът остава запазен."
    }
}
