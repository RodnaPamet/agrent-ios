import PhotosUI
import SwiftUI

/// One promotion: a new draft, or an existing one to correct, publish or
/// take down. Saving keeps it a draft; publishing is its own act (`PUT`).
struct AdminPromotionEditor: View {
    let target: EditorTarget
    let companies: [AdminPromotionsAPI.Company]

    @State private var draft: AdminPromotionsAPI.Draft
    @State private var newCompany: Bool
    @State private var isPPP: Bool
    @State private var photo: PhotosPickerItem?
    @State private var picture: Data?
    @State private var working = false
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    init(target: EditorTarget, companies: [AdminPromotionsAPI.Company]) {
        self.target = target
        self.companies = companies
        var draft = target.draft
        // A supplier read off a leaflet that the catalogue already has is
        // that supplier, compared as the server compares names.
        if draft.companyId == nil, let known = companies.first(where: {
            Self.nameKey($0.name) == Self.nameKey(draft.companyName)
        }) {
            draft.companyId = known.id
        }
        _draft = State(initialValue: draft)
        _newCompany = State(initialValue: draft.companyId == nil)
        _isPPP = State(initialValue: !draft.pppRegistrationNo.isEmpty)
    }

    /// The server's `companyNameKey`: lowercased, trimmed, inner whitespace
    /// collapsed.
    static func nameKey(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var existing: AdminPromotionsAPI.Promotion? { target.promotion }

    private var pictureLabel: String {
        if picture != nil { return "Снимката е избрана" }
        return existing?.mediaUrl == nil ? "Добави снимка" : "Смени снимката"
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    if !newCompany, !companies.isEmpty {
                        MenuPicker("Доставчик", english: "Supplier", selection: $draft.companyId,
                                   value: companies.first { $0.id == draft.companyId }?.name ?? "Изберете") {
                            ForEach(companies) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    } else {
                        TextField("Доставчик", text: $draft.companyName, prompt: .fieldPrompt("Име на доставчика"))
                    }
                    Toggle("Нов доставчик", isOn: $newCompany)
                        .onChange(of: newCompany) { _, isNew in
                            if isNew { draft.companyId = nil } else if draft.companyId == nil {
                                draft.companyId = companies.first?.id
                            }
                        }
                        .accessibilityInputLabels(A11y.spokenNames("Нов доставчик", "New supplier"))
                } header: {
                    SectionHeader("Доставчик")
                }
                Section {
                    TextField("Заглавие", text: $draft.title, prompt: .fieldPrompt("Заглавие"), axis: .vertical)
                    TextField("Текст", text: $draft.body, prompt: .fieldPrompt("Цена, условия, срок"), axis: .vertical)
                        .lineLimit(3...8)
                    MenuPicker("Вид", english: "Category", selection: $draft.category, value: draft.category.label) {
                        ForEach([PromotionsAPI.Category.culture, .fertilizer, .seeds, .products, .service], id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    TextField("Връзка", text: $draft.ctaUrl, prompt: .fieldPrompt("https://…"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                } header: {
                    SectionHeader("Промоция")
                }
                Section {
                    dateRow("Валидна от", date: $draft.validFrom)
                    dateRow("Валидна до", date: $draft.validTo)
                } header: {
                    SectionHeader("Срок")
                } footer: {
                    SectionFooter { Text("Дните са включително. Без срок промоцията е отворена.") }
                }
                Section {
                    Toggle("Продукт за растителна защита", isOn: $isPPP)
                        .onChange(of: isPPP) { _, on in
                            draft.pppChanged = true
                            if !on { draft.pppRegistrationNo = "" }
                        }
                        .accessibilityInputLabels(A11y.spokenNames("Продукт за растителна защита", "Plant protection"))
                    if isPPP {
                        TextField("Рег. № по ЗЗР", text: $draft.pppRegistrationNo, prompt: .fieldPrompt("Рег. № по ЗЗР"))
                            .onChange(of: draft.pppRegistrationNo) { draft.pppChanged = true }
                    }
                } header: {
                    SectionHeader("ПРЗ")
                } footer: {
                    SectionFooter { Text("Само за продукт за растителна защита: асистентът го показва със задължителния текст за безопасност.") }
                }
                Section {
                    let label = pictureLabel
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(label, systemImage: "photo")
                    }
                    .accessibilityInputLabels(A11y.spokenNames("Снимка", "Picture"))
                    .onChange(of: photo) { _, item in
                        guard let item else { return }
                        Task {
                            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                                picture = ScanPDF.compressed(image).jpegData(compressionQuality: ScanPDF.quality)
                            }
                        }
                    }
                    if let existing {
                        Button(existing.isPublished ? AdminPromotionsText.unpublish : AdminPromotionsText.publish) {
                            Task { await publish(!existing.isPublished) }
                        }
                        .disabled(working)
                        .accessibilityInputLabels(A11y.spokenNames(
                            existing.isPublished ? AdminPromotionsText.unpublish : AdminPromotionsText.publish))
                    }
                } footer: {
                    SectionFooter {
                        if let refusal {
                            Text(refusal).foregroundStyle(Palette.error)
                        } else if let existing {
                            Text("\(existing.status.label). Публикуваната промоция виждат всички стопанства.")
                        } else {
                            Text("Записва се като чернова. Публикувате я отделно, след като я проверите.")
                        }
                    }
                }
            }
            .inlineTitle(existing == nil ? AdminPromotionsText.new : "Промоция")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(working || !draft.canSave)
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    /// A day, or none: «Без срок» until the person picks one.
    @ViewBuilder
    private func dateRow(_ title: String, date: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { date.wrappedValue != nil },
                                    set: { date.wrappedValue = $0 ? (date.wrappedValue ?? Date()) : nil }))
            .accessibilityInputLabels(A11y.spokenNames(title))
        if let value = date.wrappedValue {
            DatePicker(title, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }),
                       displayedComponents: .date)
                .tint(Palette.DatePill.tint)
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        refusal = nil
        do {
            let id: String
            if let existing {
                try await AdminPromotionsAPI.update(existing.id, draft)
                id = existing.id
            } else {
                id = try await AdminPromotionsAPI.create(draft)
            }
            if let picture { try await AdminPromotionsAPI.uploadImage(id, jpeg: picture) }
            dismiss()
        } catch {
            refusal = UserMessage.text(for: error)
        }
    }

    private func publish(_ published: Bool) async {
        guard let existing else { return }
        working = true
        defer { working = false }
        do {
            try await AdminPromotionsAPI.setPublished(existing.id, published)
            dismiss()
        } catch {
            refusal = UserMessage.text(for: error)
        }
    }
}
