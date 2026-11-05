import PhotosUI
import SwiftUI

/// «Промоции» in Админ (#529, owner 2026-11-02): the superuser's catalogue
/// for every farm. Add from a leaflet (the server reads it and proposes;
/// the owner checks each and saves a draft) or by the form; edit; publish or
/// take down; delete what nobody has asked about; the suppliers list.
///
/// Every save, publish and delete reaches every farm, so none is made from
/// development, CI or the screenshots: the owner makes the first real one.
struct AdminPromotionsView: View {
    @State private var promotions: LoadState<[AdminPromotionsAPI.Promotion]> = .loading
    @State private var companies: [AdminPromotionsAPI.Company] = []
    @State private var editing: EditorTarget?
    @State private var scanning = false
    @State private var asking: AdminPromotionsAPI.Promotion?
    @State private var message: String?

    var body: some View {
        content
            .inlineTitle(AdminPromotionsText.title)
            .pageBackground()
            .task { await load() }
            .refreshable { await PullToRefresh.bounded { await load() } }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { target in
                AdminPromotionEditor(target: target, companies: companies)
            }
            .sheet(isPresented: $scanning) {
                AdminLeafletScanView(companies: companies) { draft in
                    scanning = false
                    // After the sheet has gone, so one sheet follows the other.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        editing = EditorTarget(promotion: nil, draft: draft)
                    }
                }
            }
            .confirmationDialog(AdminPromotionsText.deleteQuestion, isPresented: askingShown,
                                titleVisibility: .visible, presenting: asking) { promotion in
                Button(TreatmentRemoval.actionTitle, role: .destructive) {
                    Task { await run { try await AdminPromotionsAPI.delete(promotion.id) } }
                }
                .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
                Button("Отказ", role: .cancel) {}
                    .accessibilityInputLabels(A11y.Spoken.cancel)
            } message: { promotion in
                Text(promotion.title)
            }
            .alert(AdminPromotionsText.title, isPresented: messageShown, presenting: message) { _ in
                Button("Добре", role: .cancel) { message = nil }
            } message: { message in
                Text(message)
            }
    }

    private var askingShown: Binding<Bool> {
        Binding { asking != nil } set: { if !$0 { asking = nil } }
    }

    private var messageShown: Binding<Bool> {
        Binding { message != nil } set: { if !$0 { message = nil } }
    }

    @ViewBuilder
    private var content: some View {
        switch promotions {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            ErrorState(message: failure) { await load() }
        case .loaded(let rows, _):
            List {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label(AdminPromotionsText.fromLeaflet, systemImage: "doc.text.viewfinder")
                    }
                    .accessibilityInputLabels(A11y.spokenNames(AdminPromotionsText.fromLeaflet, "From a leaflet"))
                    Button {
                        editing = EditorTarget(promotion: nil, draft: AdminPromotionsAPI.Draft())
                    } label: {
                        Label(AdminPromotionsText.new, systemImage: "plus")
                    }
                    .accessibilityInputLabels(A11y.spokenNames(AdminPromotionsText.new, "New promotion"))
                } footer: {
                    SectionFooter { Text(AdminPromotionsText.addNote) }
                }
                .pageRow()
                Section {
                    if rows.isEmpty {
                        Text(AdminPromotionsText.empty)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(rows) { promotion in
                        Button {
                            editing = EditorTarget(promotion: promotion, draft: .from(promotion))
                        } label: {
                            AdminPromotionRow(promotion: promotion)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipe(promotion) }
                    }
                } header: {
                    SectionHeader(AdminPromotionsText.listTitle)
                } footer: {
                    SectionFooter { Text(AdminPromotionsText.listNote) }
                }
                .pageRow()
                Section {
                    NavigationLink {
                        AdminCompaniesView()
                    } label: {
                        Label(AdminPromotionsText.companies, systemImage: "building.2")
                    }
                    .accessibilityInputLabels(A11y.spokenNames(AdminPromotionsText.companies, "Suppliers"))
                }
                .pageRow()
            }
            .listStyle(.insetGrouped)
            .pageBackground()
        }
    }

    /// Nobody has asked: it may go. Somebody has: only «Свали», since a
    /// farm's enquiry is its record of having asked (the server refuses the
    /// delete).
    @ViewBuilder
    private func swipe(_ promotion: AdminPromotionsAPI.Promotion) -> some View {
        if promotion.leadCount == 0 {
            Button(role: .destructive) {
                asking = promotion
            } label: {
                Label(TreatmentRemoval.actionTitle, systemImage: "trash")
            }
            .accessibilityInputLabels(A11y.Spoken.deleteTreatment)
        } else if promotion.isPublished {
            Button {
                Task { await run { try await AdminPromotionsAPI.setPublished(promotion.id, false) } }
            } label: {
                Label(AdminPromotionsText.unpublish, systemImage: "eye.slash")
            }
            .tint(Palette.warning)
            .accessibilityInputLabels(A11y.spokenNames(AdminPromotionsText.unpublish, "Unpublish"))
        }
    }

    private func load() async {
        do {
            async let rows = AdminPromotionsAPI.list()
            async let suppliers = AdminPromotionsAPI.companies()
            let (loaded, known) = try await (rows, suppliers)
            promotions = .loaded(loaded, .fresh)
            companies = known
        } catch {
            if promotions.value == nil { promotions = .failed(UserMessage.text(for: error)) }
            else { message = UserMessage.text(for: error) }
        }
    }

    private func run(_ write: () async throws -> Void) async {
        do {
            try await write()
        } catch {
            message = UserMessage.text(for: error)
        }
        await load()
    }
}

/// What the editor opens on: an existing promotion, or a new draft (from
/// the form or from one of a leaflet's proposals).
struct EditorTarget: Identifiable {
    let id = UUID()
    let promotion: AdminPromotionsAPI.Promotion?
    let draft: AdminPromotionsAPI.Draft
}

private struct AdminPromotionRow: View {
    let promotion: AdminPromotionsAPI.Promotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(promotion.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(promotion.companyName)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            MetaRow {
                Text(promotion.status.label)
                if promotion.leadCount > 0 {
                    MetaSeparator()
                    Text(Plural.bg(promotion.leadCount, "запитване", "запитвания"))
                }
                if promotion.pppRegistrationNo != nil {
                    MetaSeparator()
                    Text(AdminPromotionsText.ppp)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

enum AdminPromotionsText {
    static let title = "Промоции"
    static let fromLeaflet = "От листовка"
    static let new = "Нова промоция"
    static let addNote = "Листовката се прочита и се предлагат промоциите от нея. Вие ги проверявате една по една; нищо не се записва без Вас, и нищо не стига до стопанствата, преди да го публикувате."
    static let listTitle = "Всички промоции"
    static let empty = "Още няма промоции."
    static let listNote = "Публикуваните виждат всички стопанства. Промоция, за която има запитвания, не може да бъде изтрита — може само да бъде свалена."
    static let companies = "Доставчици"
    static let unpublish = "Свали"
    static let publish = "Публикувай"
    static let ppp = "ПРЗ"
    static let deleteQuestion = "Да изтрия ли промоцията?"
}
