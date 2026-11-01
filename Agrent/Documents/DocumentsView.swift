import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// «Документи» (#468, owner 2026-10-30): the farm's document library.
/// Upload at the top, the documents below for preview, then the two
/// settings: a copy in Google Drive, and how long Agrent keeps a document.
///
/// ── Who sees what ──
///
/// Every role but MECHANISATOR (`AppSurface.isOperatorAllowed`): READER and
/// AUDITOR view; OWNER, ADMIN and writers upload (`CurrentUser.mayWrite`);
/// OWNER and ADMIN change the settings (`DocumentSettings.mayEdit`).
///
/// ── The camera at the top right ──
///
/// The owner asked for a quick way to photograph a paper, and to scan it if
/// possible: the button opens VisionKit's scanner straight away, and its
/// pages become one PDF (`ScanPDF`). With no scanner it takes a photo.
struct DocumentsView: View {
    var body: some View {
        RoutedStack {
            DocumentsScreen()
        }
    }
}

private struct DocumentsScreen: View {
    @State private var store = DocumentsStore()
    @State private var people = CurrentUserStore.shared
    @State private var removal = DocumentRemoval()
    @State private var connect = GoogleDriveConnect()
    @State private var flags = FeatureFlags.shared

    @State private var pending: DocumentUpload?
    @State private var scanning = false
    @State private var photographing = false
    @State private var importing = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: PreviewFile?
    @State private var opening: String?
    @State private var asking: FarmDocument?
    @State private var confirming = false
    @State private var showsMessage = false
    /// A document read into expenses (#482): «От фактура» once it has lines.
    @State private var invoice: InvoiceReview?

    private var mayUpload: Bool { people.user?.mayWrite == true }

    var body: some View {
        content
            .navigationTitle("Документи")
            .appMenu()
            .toolbar {
                if mayUpload {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            startCamera()
                        } label: {
                            Label("Сканирай", systemImage: "doc.viewfinder")
                        }
                        .accessibilityInputLabels(A11y.Spoken.scan)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let undoable = removal.undoable { undoBar(undoable) }
            }
            .alert(DocumentRemoval.confirmTitle, isPresented: $confirming, presenting: asking) { document in
                Button(TreatmentRemoval.actionTitle, role: .destructive) { remove(document) }
                    .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: { _ in
                Text(DocumentRemoval.confirmMessage)
            }
            .alert("Документът не е изтрит", isPresented: Bindable(removal).showsFailure, presenting: removal.failure) { _ in
                Button("Затвори", role: .cancel) { removal.dismissFailure() }
            } message: { failure in
                Text(failure)
            }
            .alert("Документи", isPresented: $showsMessage, presenting: store.message) { _ in
                Button("Затвори", role: .cancel) { store.message = nil }
            } message: { message in
                Text(message)
            }
            .onChange(of: store.message) { _, message in showsMessage = message != nil }
            .onChange(of: removal.deletions) {
                Task {
                    await store.load()
                    removal.listRead()
                }
            }
            .sheet(item: $invoice) { review in
                InvoiceReviewView(review: review, crops: []) {}
            }
            .sheet(item: $pending) { file in
                DocumentUploadSheet(file: file, settings: store.settings.value, store: store)
            }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { pages in
                    scanning = false
                    guard !pages.isEmpty else { return }
                    let pdf = ScanPDF.make(pages)
                    DispatchQueue.main.async {
                        pending = DocumentUploads.scan(pdf)
                        UsageEvents.shared.record(.documentScanned)
                    }
                } onCancel: {
                    scanning = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $photographing) {
                CameraPicker { image in
                    photographing = false
                    if let upload = DocumentUploads.photo(image) {
                        DispatchQueue.main.async { pending = upload }
                    }
                } onCancel: {
                    photographing = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $preview, onDismiss: { preview?.remove() }) { file in
                DocumentPreview(file: file.url, title: file.title) {
                    file.remove()
                    preview = nil
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    switch DocumentUploads.file(at: url) {
                    case .success(let upload): pending = upload
                    case .failure(let refusal): store.message = refusal.message
                    }
                case .failure:
                    break
                }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let upload = DocumentUploads.photo(image) {
                        pending = upload
                    }
                }
            }
            .task { if store.page.value == nil { await store.load() } }
            .task { _ = await people.load() }
            // A copy on its way to Drive (agri-saas #2573): the sweep runs
            // every two minutes, so the list reads again every thirty seconds
            // while one is PENDING and the page is open, ten minutes at most,
            // and stops the moment none is.
            .task(id: store.awaitsDriveCopy) {
                for _ in 0..<20 where store.awaitsDriveCopy {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await store.refreshQuietly()
                }
            }
    }

    // MARK: - The page

    @ViewBuilder
    private var content: some View {
        switch store.page {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded(let page, _):
            List {
                Group {
                    if mayUpload { uploadRow }
                    if page.truncated {
                        RefusalNote(
                            text: "Списъкът е съкратен от сървъра. Не всички документи се показват.",
                            icon: "exclamationmark.triangle"
                        )
                    }
                    documents(removal.visible(page.items))
                    settingsSection
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }

    /// «Качи документ»: from Files, from Photos, or the scanner, the same
    /// one the top-right button opens.
    private var uploadRow: some View {
        Menu {
            Button {
                importing = true
            } label: {
                Label("От файловете", systemImage: "folder")
            }
            Button {
                choosingPhoto = true
            } label: {
                Label("От снимките", systemImage: "photo.on.rectangle")
            }
            Button {
                startCamera()
            } label: {
                Label(DocumentScanner.isAvailable ? "Сканирай" : "Снимай", systemImage: "doc.viewfinder")
            }
        } label: {
            Label("Качи документ", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .prominentButton()
        .controlSize(.large)
        .disabled(store.uploading != nil)
        .accessibilityInputLabels(A11y.Spoken.uploadDocument)
        .listRowSeparator(.hidden)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func documents(_ items: [FarmDocument]) -> some View {
        if items.isEmpty && store.uploading == nil {
            Text("Няма качени документи.")
                .font(.body)
                .foregroundStyle(Palette.secondaryText)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
        } else {
            Section(titled: Plural.bg(items.count, "документ", "документа")) {
                if let name = store.uploading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Качва се: \(name)")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                ForEach(items) { document in
                    row(document)
                        .pageRow()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ document: FarmDocument) -> some View {
        let text = DocumentRowText(document)
        let body = DocumentRow(text: text, kind: DocumentKind(contentType: document.contentType),
                               purged: document.isPurged, opening: opening == document.id)
        Group {
            if document.isPurged {
                body
            } else {
                Button { Task { await open(document) } } label: { body }
                    .buttonStyle(.plain)
                    .accessibilityHint("Отваря документа")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if DocumentRemoval.offered(document, to: people.user) {
                Button(role: .destructive) {
                    asking = document
                    confirming = true
                } label: {
                    Label(TreatmentRemoval.actionTitle, systemImage: "trash")
                }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // An invoice already here, into expenses (owner, 2026-10-31):
            // read by the server from the bytes it holds, then «От фактура».
            if !document.isPurged, people.user?.mayWrite == true {
                Button {
                    Task { await readInvoice(document) }
                } label: {
                    Label("Към разходи", systemImage: "eurosign.circle")
                }
                .tint(Palette.accent)
                .accessibilityInputLabels(A11y.spokenNames("Към разходи", "Разходи"))
            }
            if text.driveFailed, store.settings.value?.mayEdit == true {
                Button {
                    Task { await store.retryDriveCopy(document) }
                } label: {
                    Label("Опитай пак", systemImage: "arrow.clockwise")
                }
                .tint(Palette.accent)
                .accessibilityInputLabels(A11y.Spoken.retry)
            }
        }
    }

    /// The document read as an invoice: «От фактура» with its lines, or
    /// why not. The row shows it working, as it does while opening.
    private func readInvoice(_ document: FarmDocument) async {
        guard opening == nil else { return }
        opening = document.id
        defer { opening = nil }
        do {
            let scan = try await InvoiceScanAPI.scan(documentId: document.id)
            if scan.lines.isEmpty {
                store.message = UserMessage.bulgarian["INVOICE_NO_USABLE_LINES"]
            } else {
                invoice = InvoiceReview(scan, crops: [])
            }
        } catch {
            store.message = UserMessage.text(for: error)
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsSection: some View {
        if let settings = store.settings.value {
            Section {
                Toggle(isOn: driveBinding(settings)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Копие в Google Drive")
                        Text(DriveSwitchText.detail(settings, mayConnect: flags.isOn(GoogleDriveConnect.flag)))
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mayEdit || store.saving)

                Picker("Срок на съхранение", selection: retentionBinding(settings)) {
                    ForEach(DocumentRetention.choices, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!settings.mayEdit || store.saving || settings.retention == .unknown)

                VStack(alignment: .leading, spacing: 6) {
                    Text(DocumentSize.usage(used: settings.usedBytes, limit: settings.limitBytes))
                        .font(.subheadline)
                    if settings.limitBytes > 0 {
                        ProgressView(value: min(Double(settings.usedBytes) / Double(settings.limitBytes), 1))
                            .tint(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                SectionHeader("Настройки")
            } footer: {
                SectionFooter(settings.mayEdit
                    ? "Срокът важи за документите, качени отсега нататък."
                    : "Само собственик или администратор може да ги променя.")
            }
        }
    }

    /// On: connect Google first where it isn't, then switch. Off: only the
    /// switch; the connection stays, as the ДНЕВНИК export uses it.
    private func driveBinding(_ settings: DocumentSettings) -> Binding<Bool> {
        Binding {
            settings.driveSync && settings.google?.connected == true
        } set: { on in
            Task {
                if on, settings.google?.connected != true {
                    // Not connected and no way to connect from here: said,
                    // rather than a 404 from a route that is switched off.
                    guard flags.isOn(GoogleDriveConnect.flag) else {
                        store.message = DriveSwitchText.connectOff
                        return
                    }
                    switch await connect.run() {
                    case .connected: break
                    case .cancelled: return
                    case .refused(let message):
                        store.message = message
                        return
                    }
                }
                await store.update(driveSync: on)
            }
        }
    }

    private func retentionBinding(_ settings: DocumentSettings) -> Binding<DocumentRetention> {
        Binding {
            settings.retention
        } set: { choice in
            Task { await store.update(retention: choice) }
        }
    }

    // MARK: - Actions

    private func startCamera() {
        if DocumentScanner.isAvailable {
            scanning = true
        } else if CameraPicker.isAvailable {
            photographing = true
        } else {
            choosingPhoto = true
        }
    }

    private func open(_ document: FarmDocument) async {
        guard opening == nil else { return }
        opening = document.id
        defer { opening = nil }
        do {
            let (data, fileName) = try await DocumentsAPI.content(document.id)
            preview = try PreviewFile.write(data, title: document.name ?? "Документ",
                                            fileName: fileName, contentType: document.contentType)
        } catch {
            store.message = UserMessage.text(for: error)
        }
    }

    private func remove(_ document: FarmDocument) {
        let assisted = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        removal.remove(document, window: assisted ? TreatmentRemoval.assistedWindow : nil)
        if let going = removal.undoable {
            var said = AttributedString(DocumentRemoval.announcement(going))
            said.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(said).post()
        }
    }

    private func undoBar(_ undoable: DocumentRemoval.Undoable) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DocumentRemoval.removedText(undoable))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(TreatmentRemoval.undoTitle) { removal.undo() }
                .fontWeight(.semibold)
                .accessibilityInputLabels(A11y.Spoken.undo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidBar(hairline: .top)
    }
}

/// One document: its kind's icon, name, details, and where it stands.
private struct DocumentRow: View {
    let text: DocumentRowText
    let kind: DocumentKind
    let purged: Bool
    let opening: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: purged ? "doc.badge.ellipsis" : kind.icon)
                .font(.title3)
                .foregroundStyle(purged ? Palette.secondaryText : Palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title)
                    .font(.headline)
                    .foregroundStyle(purged ? Palette.secondaryText : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !text.details.isEmpty {
                    Text(ParcelHistoryLine.joined(text.details))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text.status)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let drive = text.drive {
                    Text(drive)
                        .font(.footnote)
                        .foregroundStyle(text.driveFailed ? Palette.warning : Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if opening { ProgressView() }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
    }
}

/// What the Drive switch says under itself.
enum DriveSwitchText {
    static let connectOff = "Свързването с Google Drive не е включено за стопанството."

    static func detail(_ settings: DocumentSettings, mayConnect: Bool = true) -> String {
        if settings.google?.connected == true {
            if let email = settings.google?.accountEmail?.recorded {
                return "В папка «Agrent» в \(email)."
            }
            return "В папка «Agrent» в Google Drive на стопанството."
        }
        guard settings.mayEdit else { return "Стопанството не е свързано с Google Drive." }
        return mayConnect
            ? "При включване ще ви помоли да влезете в Google акаунта на стопанството."
            : connectOff
    }
}
