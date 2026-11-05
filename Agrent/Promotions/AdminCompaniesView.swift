import SwiftUI

/// «Доставчици» (#529): the companies offers are filed under. A supplier is
/// added with its first promotion (by name); here they are corrected. Two
/// with one name are refused (`COMPANY_NAME_TAKEN`).
struct AdminCompaniesView: View {
    @State private var companies: LoadState<[AdminPromotionsAPI.Company]> = .loading
    @State private var editing: AdminPromotionsAPI.Company?

    var body: some View {
        content
            .inlineTitle(AdminPromotionsText.companies)
            .pageBackground()
            .task { await load() }
            .refreshable { await PullToRefresh.bounded { await load() } }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { AdminCompanyEditor(company: $0) }
    }

    @ViewBuilder
    private var content: some View {
        switch companies {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            ErrorState(message: failure) { await load() }
        case .loaded(let rows, _) where rows.isEmpty:
            EmptyState("Още няма доставчици", icon: "building.2",
                       message: "Доставчикът се добавя с първата си промоция.")
        case .loaded(let rows, _):
            List {
                Section {
                    ForEach(rows) { company in
                        Button { editing = company } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(company.name).font(.subheadline.weight(.semibold))
                                Text(Plural.bg(company.promotionCount, "промоция", "промоции"))
                                    .font(.footnote).foregroundStyle(Palette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
                .pageRow()
            }
            .listStyle(.insetGrouped)
            .pageBackground()
        }
    }

    private func load() async {
        do {
            companies = .loaded(try await AdminPromotionsAPI.companies(), .fresh)
        } catch {
            if companies.value == nil { companies = .failed(UserMessage.text(for: error)) }
        }
    }
}

private struct AdminCompanyEditor: View {
    let company: AdminPromotionsAPI.Company

    @State private var name: String
    @State private var eik: String
    @State private var website: String
    @State private var contact: String
    @State private var email: String
    @State private var phone: String
    @State private var notes: String
    @State private var saving = false
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    init(company: AdminPromotionsAPI.Company) {
        self.company = company
        _name = State(initialValue: company.name)
        _eik = State(initialValue: company.eik ?? "")
        _website = State(initialValue: company.websiteUrl ?? "")
        _contact = State(initialValue: company.contactName ?? "")
        _email = State(initialValue: company.contactEmail ?? "")
        _phone = State(initialValue: company.contactPhone ?? "")
        _notes = State(initialValue: company.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    TextField("Име", text: $name, prompt: .fieldPrompt("Име на доставчика"))
                    TextField("ЕИК", text: $eik, prompt: .fieldPrompt("ЕИК")).keyboardType(.numberPad)
                    TextField("Уебсайт", text: $website, prompt: .fieldPrompt("https://…"))
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                } header: {
                    SectionHeader("Доставчик")
                }
                Section {
                    TextField("Лице за контакт", text: $contact, prompt: .fieldPrompt("Име"))
                    TextField("Имейл", text: $email, prompt: .fieldPrompt("Имейл"))
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Телефон", text: $phone, prompt: .fieldPrompt("Телефон")).keyboardType(.phonePad)
                    TextField("Бележки", text: $notes, prompt: .fieldPrompt("Бележки"), axis: .vertical)
                } header: {
                    SectionHeader("Контакт")
                } footer: {
                    SectionFooter {
                        if let refusal { Text(refusal).foregroundStyle(Palette.error) }
                    }
                }
            }
            .inlineTitle(AdminPromotionsText.companies)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(saving || name.recorded == nil)
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await AdminPromotionsAPI.updateCompany(company.id, .init(
                name: name.recorded ?? company.name, eik: eik.recorded, websiteUrl: website.recorded,
                contactName: contact.recorded, contactEmail: email.recorded, contactPhone: phone.recorded,
                notes: notes.recorded))
            dismiss()
        } catch {
            refusal = UserMessage.text(for: error)
        }
    }
}
