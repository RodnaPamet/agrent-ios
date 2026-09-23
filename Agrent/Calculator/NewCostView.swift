import SwiftUI

/// Add a cost to the farm's books.
///
/// ── This form does NOT retry, and that is the whole design ──
///
/// The grain routes honour no idempotency: POST twice, with any key or
/// none, and there are two rows. So a duplicate here is a duplicated
/// financial record that silently changes net worth, and nothing upstream
/// will catch it.
///
/// Everything below follows from that:
///
///   - No automatic retry, no queue, no pull-to-refresh on a failed save.
///   - The button disables the instant it is pressed and does not come
///     back while the request is in flight, so a second tap cannot exist.
///   - A TIMEOUT is reported as unknown rather than as failure. After one
///     the app genuinely does not know whether the row was written, and
///     "не бе записан" invites the operator to enter it again — the single
///     action that makes it worse.
struct NewCostView: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var category: CostCategory = .fuel
    @State private var amountText = ""
    @State private var currency = "BGN"
    @State private var incurredOn = Date()
    @State private var supplier = ""
    @State private var notes = ""

    @State private var saving = false
    @State private var failure: Failure?

    private enum Failure: Equatable {
        /// The server answered and said no. The row does not exist.
        case refused(String)
        /// No answer arrived. The row may or may not exist, and only the
        /// books can say which.
        case unknown(String)
    }

    /// Parsed with an explicit locale, not `Decimal(string:)`'s default.
    /// A Bulgarian keyboard produces "12,50" and the wire wants 12.5; the
    /// device also reports en_BG, so neither the comma nor the full stop
    /// can be assumed. Both are accepted and normalised here.
    private var amount: Decimal? {
        let cleaned = amountText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var draft: CreateCostEntry? {
        guard let amount else { return nil }
        return CreateCostEntry(
            category: category,
            amount: amount,
            currency: currency.trimmingCharacters(in: .whitespaces).uppercased(),
            // yyyy-mm-dd, which is what a `min(8)` string field means here.
            incurredOn: incurredOn.formatted(
                .iso8601.year().month().day().dateSeparator(.dash)
            ),
            supplier: supplier.isEmpty ? nil : supplier,
            description: notes.isEmpty ? nil : notes
        )
    }

    private var canSave: Bool {
        guard !saving, let draft else { return false }
        return draft.problems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Категория", selection: $category) {
                        ForEach(CostCategory.selectable, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    // `.decimalPad` has no minus sign, which is right: the
                    // server requires amount > 0 and a negative cost is a
                    // different concept the books do not have here.
                    TextField("Сума", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Валута", text: $currency)
                        .textInputAutocapitalization(.characters)
                    DatePicker("Дата", selection: $incurredOn, displayedComponents: .date)
                }

                Section("Доставчик") {
                    TextField("по избор", text: $supplier, axis: .vertical)
                }
                Section("Бележки") {
                    TextEditor(text: $notes).frame(minHeight: 100)
                }

                if let problem = firstProblemText {
                    Section { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                }

                if let failure {
                    Section { failureView(failure) }
                }
            }
            .inlineTitle("Нов разход")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Запази") { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    @ViewBuilder
    private func failureView(_ failure: Failure) -> some View {
        switch failure {
        case .refused(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(Palette.error)
                Text("Разходът НЕ е записан. Можете да опитате отново.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .unknown(let message):
            // The honest answer, and it is deliberately not a retry button.
            // Without idempotency, a second attempt after a lost response
            // is how one cost becomes two.
            VStack(alignment: .leading, spacing: 6) {
                Label("Неясен резултат", systemImage: "questionmark.circle")
                    .foregroundStyle(Palette.error)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Text("""
                    Връзката прекъсна, преди сървърът да отговори. Разходът \
                    може да е записан, а може и да не е. Проверете списъка с \
                    разходи, преди да го въведете отново — повторното \
                    въвеждане създава втори запис.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var firstProblemText: String? {
        guard !amountText.isEmpty, let draft else {
            return amountText.isEmpty ? nil : "Сумата не е разчетена."
        }
        switch draft.problems.first {
        case .amountNotPositive: return "Сумата трябва да е по-голяма от нула."
        case .amountTooLarge: return "Сумата е прекалено голяма."
        case .currencyMissing: return "Валутата е задължителна."
        case .dateMissing: return "Датата е задължителна."
        case nil: return nil
        }
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        failure = nil
        defer { saving = false }

        do {
            _ = try await CostsAPI.create(draft)
            onSaved()
            dismiss()
        } catch let error as URLError {
            // A transport failure is the ambiguous one: the request may
            // have reached the server and been written before the answer
            // was lost.
            failure = .unknown(UserMessage.text(for: error))
        } catch {
            // The server answered. Whatever it said, it said it — so the
            // row does not exist and trying again is safe.
            failure = .refused(UserMessage.text(for: error))
        }
    }
}
