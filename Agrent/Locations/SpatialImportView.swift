import SwiftUI
import UniformTypeIdentifiers

/// Import parcel boundaries into one location.
///
/// ── THE WARNING SAYS "ADDS", AND THAT WAS NEARLY WRONG ──
///
/// This screen was two hours from shipping «Ще замени 14 парцела» — that the
/// import REPLACES the location's parcels. The server's own route description
/// says "the worker REPLACES the location's parcels", and I built against it.
///
/// It does not. `addParcelsForLocation` only ever creates: no `deleteMany`, no
/// upsert, no uniqueness. The worker's own docblock says so in terms — "Import
/// is ADDITIVE … appends the parsed parcels and KEEPS the location's existing
/// ones — so it is NOT idempotent" — and the two descriptions contradict each
/// other. Caught by the server session going to the worker to confirm the
/// premise before writing an issue from my relay.
///
/// So the true risk is the opposite of the one I was about to warn about, and
/// the copy errs the other way: not "you will lose your parcels" but "you will
/// get two of each". Re-importing the same file gives the location a second
/// copy of every field — the original keeping all its history, the new one
/// empty — and a farmer looking at the map sees each field twice, one of them
/// apparently blank.
///
/// Geometry-matched import with history carried across is filed as
/// agri-saas#1116. When it lands this copy changes again, and the direction it
/// changes in is the reason to state today's behaviour rather than tomorrow's.
struct SpatialImportView: View {
    let locationID: String
    let locationName: String
    /// What is on the map right now, so the warning names a real number
    /// rather than "your parcels".
    let existingParcelCount: Int
    let onFinished: () -> Void

    @State private var picking = false
    @State private var chosen: ChosenFile?
    @State private var refusal: SpatialImportRefusal?
    @State private var cropType: ChartableCommodity?
    @State private var phase: Phase = .choosing
    @Environment(\.dismiss) private var dismiss

    struct ChosenFile: Equatable {
        let name: String
        let bytes: Data
        let format: SpatialImportFormat
    }

    enum Phase: Equatable {
        case choosing
        case uploading
        /// Polling. The 202 is not an import — nothing has changed on the
        /// server when it returns, so the map must not be refreshed on it.
        case working(jobId: String, stage: ImportJobStage)
        case done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .choosing: chooser
                case .uploading, .working, .done, .failed: progress
                }
            }
            .inlineTitle("Импорт на граници")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Готово" : "Отказ") {
                        if phase == .done { onFinished() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .choosing {
                        Button("Импортирай") { Task { await start() } }
                            .disabled(chosen == nil)
                    }
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in choose(result) }
        }
    }

    // MARK: - Choosing

    @ViewBuilder
    private var chooser: some View {
        Section {
            Button {
                picking = true
            } label: {
                Label(chosen == nil ? "Избери файл" : "Избери друг файл",
                      systemImage: "doc.badge.plus")
            }

            if let chosen {
                LabeledContent(chosen.name) {
                    Text("\(Num.text(Double(chosen.bytes.count) / (1024 * 1024))) MB")
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityLabel(A11y.sentence([chosen.name, chosen.format.label]))
            }

            if let refusal {
                RefusalNote(text: refusal.text, icon: "exclamationmark.triangle")
            }
        } header: {
            Text("Файл")
        } footer: {
            // A shapefile is `.shp` plus `.dbf` plus `.shx` at minimum, so the
            // bare `.shp` a farmer sees in a folder is not what the server
            // needs. Said here rather than discovered from a refusal.
            Text("Shapefile се качва като .zip с всички части. Приемат се "
                 + "и .kml/.kmz и .geojson.")
        }

        Section {
            Picker("Култура", selection: $cropType) {
                Text("Смесени / по-късно").tag(ChartableCommodity?.none)
                ForEach(ChartableCommodity.allCases.filter { !$0.isInput }) { crop in
                    Text(crop.label).tag(Optional(crop))
                }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text("Стъпва се на всеки импортиран парцел. Може да се смени после.")
        }

        Section {
            // ADDS. The word is the whole point — see this type's header for
            // the warning that was nearly shipped instead.
            Label(
                existingParcelCount > 0
                    ? "Импортът ДОБАВЯ парцели към «\(locationName)» — не заменя "
                      + "съществуващите. Сега там има "
                      + "\(Plural.bg(existingParcelCount, "парцел", "парцела"))."
                    : "Импортът добавя парцелите от файла към «\(locationName)».",
                systemImage: "plus.square.on.square")
                .font(.footnote)

            if existingParcelCount > 0 {
                Label(
                    "Ако този файл вече е импортиран, всяко поле ще се появи втори път.",
                    systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    // MARK: - Working

    @ViewBuilder
    private var progress: some View {
        Section {
            switch phase {
            case .choosing:
                EmptyView()

            case .uploading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Качва се…")
                }

            case .working(_, let stage):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(stage.text)
                }

            case .done:
                Label("Импортът завърши.", systemImage: "checkmark.circle")
                    .foregroundStyle(Palette.accent)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if case .working = phase {
                // The parse never runs on the request thread and the map must
                // not be refreshed until the job reports finished — so the
                // screen says why it is still here.
                Text("Границите се обработват на сървъра. Картата се "
                     + "обновява, когато приключи.")
            }
        }
    }

    // MARK: - Actions

    /// Every accepted extension, as UTIs.
    ///
    /// `.zip` and `.json` resolve to system types; `.kml`, `.kmz` and
    /// `.geojson` do not reliably, so they are declared by filename extension.
    /// A picker that silently offered fewer kinds than the server accepts
    /// would be a refusal with no message at all.
    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.zip, .json]
        for ext in ["kml", "kmz", "geojson"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private func choose(_ result: Result<[URL], Error>) {
        chosen = nil
        refusal = nil
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                phase = .failed(UserMessage.text(for: error))
            }
            return
        }

        // SECURITY SCOPE. A document-picker URL is not readable without it,
        // and the failure is a permissions error rather than a missing file —
        // which reads as a bug in the app.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            refusal = .empty
            return
        }

        // Checked on the BYTES actually read, not on the filesystem's declared
        // size: those differ for a cloud file that has not been downloaded,
        // and the server enforces its cap on what arrives.
        if let stop = SpatialImportFormat.refusal(forFile: name, bytes: data.count) {
            refusal = stop
            return
        }
        guard let format = SpatialImportFormat.forFile(named: name) else { return }
        chosen = ChosenFile(name: name, bytes: data, format: format)
    }

    private func start() async {
        guard let chosen else { return }
        phase = .uploading
        do {
            let accepted = try await SpatialImportAPI.upload(
                locationID: locationID,
                file: chosen.bytes,
                fileName: chosen.name,
                format: chosen.format,
                cropType: cropType?.rawValue
            )
            phase = .working(jobId: accepted.jobId, stage: .waiting)
            await poll(jobId: accepted.jobId)
        } catch {
            phase = .failed(UserMessage.text(for: error))
        }
    }

    /// Poll until the job stops moving.
    ///
    /// A bounded number of attempts rather than `while true`: a queue that
    /// never reports terminal would otherwise hold the screen and the
    /// connection forever. Stopping says so instead of pretending it finished
    /// — the job may still complete, and the map picks it up next time.
    private func poll(jobId: String) async {
        for _ in 0..<Self.maxPolls {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            do {
                let status = try await SpatialImportAPI.job(
                    locationID: locationID, jobID: jobId)
                phase = .working(jobId: jobId, stage: status.stage)

                switch status.stage {
                case .done:
                    phase = .done
                    onFinished()
                    return
                case .failed:
                    phase = .failed(status.failedReason?.recorded
                                    ?? "Импортът не успя.")
                    return
                case .waiting, .running, .unknown:
                    continue
                }
            } catch {
                phase = .failed(UserMessage.text(for: error))
                return
            }
        }
        phase = .failed("Обработката още продължава. Проверете локацията по-късно.")
    }

    /// Two minutes at two seconds a poll. Long enough for a parse of a file
    /// inside the byte caps, short enough that a farmer is not held by a queue
    /// that has stopped answering.
    private static let maxPolls = 60
}
