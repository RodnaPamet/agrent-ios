import SwiftUI

/// «Нов тракер» (#574): a GPS tracker on one of the farm's machines.
///
/// Three steps in one form: the machine (one from the register, or a new
/// one, as the first tracker always means a first machine), the tracker's
/// IMEI, and the confirmation the owner required, that the drivers were
/// told the machine is tracked and who sees it. The server refuses a
/// tracker without it and records who confirmed it and when.
///
/// The device setup (where the tracker reports) comes from the server and
/// is shown here to copy into the Teltonika configurator; when the server
/// has none set up, the form says so rather than leaving a blank.
struct AddTrackerSheet: View {
    let register: TrackerRegister?
    let onSaved: () -> Void

    @State private var assets: [MachineAsset] = []
    @State private var assetID: String = AddTrackerSheet.newMachine
    @State private var name = ""
    @State private var kind: MachineKind = .tractor
    @State private var imei = ""
    @State private var label = ""
    @State private var driversInformed = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    static let newMachine = "__new"

    private var creatingMachine: Bool { assetID == Self.newMachine }

    private var machineName: String {
        creatingMachine ? "Нова машина" : assets.first { $0.id == assetID }?.name ?? "Машина"
    }

    private var ready: Bool {
        IMEI.isValid(imei) && driversInformed
            && (!creatingMachine || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    MenuPicker("Машина", selection: $assetID, value: machineName) {
                        Text("Нова машина").tag(Self.newMachine)
                        ForEach(assets.filter(\.isMachine)) { asset in
                            Text(asset.name).tag(asset.id)
                        }
                    }
                    if creatingMachine {
                        TextField("Име", text: $name, prompt: .fieldPrompt("напр. John Deere 6155M"))
                        MenuPicker("Вид", selection: $kind, value: kind.label) {
                            ForEach(MachineKind.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    SectionHeader("Машина")
                }

                Section {
                    TextField("IMEI", text: $imei, prompt: .fieldPrompt("15 цифри от етикета на тракера"))
                        .keyboardType(.numberPad)
                    TextField("Къде е монтиран", text: $label, prompt: .fieldPrompt("по желание, напр. в кабината"))
                } header: {
                    SectionHeader("Тракер")
                } footer: {
                    SectionFooter {
                        if !imei.isEmpty, !IMEI.isValid(imei) {
                            Text("Проверете IMEI: трябва да е 15 цифри.").foregroundStyle(Palette.error)
                        } else {
                            Text("Изписан е на етикета на тракера и на кутията му.")
                        }
                    }
                }

                Section {
                    Toggle("Шофьорите са уведомени, че машината се проследява и кой вижда местоположението ѝ",
                           isOn: $driversInformed)
                } header: {
                    SectionHeader("Шофьори")
                } footer: {
                    SectionFooter("Задължително. Механизаторите виждат в приложението кои машини се проследяват; техните телефони не се проследяват.")
                }

                Section {
                    Text(Self.setup(register?.ingest))
                        .font(.footnote)
                        .textSelection(.enabled)
                } header: {
                    SectionHeader("Настройка на тракера")
                } footer: {
                    SectionFooter {
                        if let failure {
                            Text(failure).foregroundStyle(Palette.error)
                        }
                    }
                }
            }
            .inlineTitle("Нов тракер")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(!ready || saving)
                        .accessibilityHint(ready ? "" : "Попълнете машината и IMEI и потвърдете, че шофьорите са уведомени.")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                assets = (try? await MachinesAPI.assets()) ?? []
            }
        }
    }

    /// What to type into the tracker's configurator, or why there is nothing.
    nonisolated static func setup(_ ingest: TrackerRegister.Ingest?) -> String {
        guard let ingest else {
            return "Сървърът за GPS тракери още не е настроен. Тракерът може да се добави, но няма да подава сигнал, докато не бъде."
        }
        return "В конфигуратора на тракера задайте сървър \(ingest.host), порт \(ingest.port), протокол TCP (Codec 8)."
    }

    private func save() async {
        guard ready, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            var machine = assetID
            if creatingMachine {
                machine = try await MachinesAPI.createAsset(.init(
                    name: name.trimmingCharacters(in: .whitespaces), type: kind.rawValue,
                    manufacturer: nil, model: nil))
                // A retry after a failed tracker reuses the machine just made.
                assetID = machine
                assets.append(MachineAsset(id: machine, name: name, type: kind.rawValue))
            }
            let place = label.trimmingCharacters(in: .whitespaces)
            try await MachinesAPI.addTracker(.init(
                assetId: machine, imei: IMEI.normalised(imei), label: place.isEmpty ? nil : place,
                driversInformed: true))
            onSaved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}
