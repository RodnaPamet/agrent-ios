import SwiftUI

/// «От фактура» (#482): an invoice's lines, read by the server, for the
/// person to check and correct, then «Запиши» — the owner's "fill the form,
/// you tap «Запиши»". Nothing is stored before that tap; the save is the
/// ordinary sheet, one expense per line, each pointing at the invoice.
struct InvoiceReviewView: View {
    let onSaved: () -> Void

    @State private var review: InvoiceReview
    @State private var crops: [CropChoice]
    @State private var nonce = UUID().uuidString
    @State private var saving = false
    @State private var failure: String?
    /// The last save's answer was lost: it may be in the books, so it is not
    /// sent again from here (the owner's rule for a cost, 2026-09-25).
    @State private var answerLost = false

    @Environment(\.dismiss) private var dismiss

    init(review: InvoiceReview, crops: [CropChoice], onSaved: @escaping () -> Void) {
        _review = State(initialValue: review)
        _crops = State(initialValue: crops)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    Text(InvoiceReview.checkFirst)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(review.warnings, id: \.code) { warning in
                        Label(InvoiceReview.text(warning), systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(Palette.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(review.rows.indices), id: \.self) { index in
                    rowSection(index)
                }
            }
            .inlineTitle("От фактура")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запиши") { Task { await save() } }
                            .disabled(review.sheet == nil || answerLost)
                            .accessibilityInputLabels(A11y.Spoken.save)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task { if crops.isEmpty { await loadCrops() } }
        }
    }

    @ViewBuilder
    private func rowSection(_ index: Int) -> some View {
        let row = $review.rows[index]
        Section(titled: "Ред \(index + 1)") {
            MenuPicker("Вид", selection: row.category, value: row.wrappedValue.category.label) {
                ForEach(CostCategory.selectable, id: \.self) { Text($0.label).tag($0) }
            }
            FieldRow("Сума, EUR") {
                TextField("Сума", text: row.amountText, prompt: .fieldPrompt("0,00"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            DatePicker("Дата", selection: row.incurredOn, displayedComponents: .date)
                .tint(Palette.DatePill.tint)
            TextField("Доставчик", text: row.supplier, prompt: .fieldPrompt("Доставчик"))
            TextField("Бележка", text: row.note, prompt: .fieldPrompt("Бележка"), axis: .vertical)
            MenuPicker("За", selection: row.attribution, value: InvoiceReview.label(row.wrappedValue.attribution)) {
                Text(InvoiceReview.farmLabel).tag(InvoiceReview.Attribution.farm)
                ForEach(crops) { crop in
                    Text(crop.name).tag(InvoiceReview.Attribution.crop(crop.id))
                }
            }
            if let problem = review.problems.first(where: { Self.row(of: $0) == index }) {
                Text(InvoiceReview.text(problem))
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
            }
            if review.rows.count > 1 {
                Button("Премахни реда", role: .destructive) {
                    review.rows.remove(at: index)
                }
                .disabled(saving || answerLost)
                .accessibilityInputLabels(A11y.spokenNames("Премахни реда", "Премахни"))
            }
        }
        .disabled(saving || answerLost)
    }

    static func row(of problem: InvoiceReview.Problem) -> Int? {
        switch problem {
        case .noLines: nil
        case .categoryMissing(let row), .amountUnreadable(let row), .amountOutOfRange(let row): row
        }
    }

    /// The crops with land, as «Нов разход» offers them, read here when the
    /// review was opened from somewhere that had none («Документи»).
    private func loadCrops() async {
        guard let data = try? await APIClient.shared.data(for: CalculatorAPI.path),
              let payload = try? await CalculatorAPI.decode(from: data) else { return }
        crops = CropChoice.from(payload.rows)
    }

    private func save() async {
        guard let sheet = review.sheet, !saving, !answerLost else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            _ = try await CostsAPI.createSheet(
                sheet, idempotencyKey: CostIdempotencyKey.mint(nonce: nonce, draft: sheet))
            onSaved()
            dismiss()
        } catch let error as URLError {
            answerLost = true
            failure = UserMessage.text(for: error)
                + " Разходите може да са записани. Проверете «Разходи» в Калкулатора, преди да ги въведете отново."
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

extension InvoiceReview: Identifiable {
    var id: String { invoiceFileId }
}
