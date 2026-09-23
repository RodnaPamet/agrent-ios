import SwiftUI

/// Post an offer to the board.
///
/// ── NEVER RETRIED, and this is the strictest write in the app ──
///
/// The route honours no idempotency and there is no natural key, so a
/// replay puts a SECOND OFFER on a board every tenant in the platform can
/// see, under this farm's name. Withdrawing it is a public act.
///
/// That is the cost form's problem with an audience: a duplicated cost is
/// wrong on one farm's books, a duplicated offer is wrong in front of
/// everyone else's. So the button disables on press and does not return
/// while the request is in flight, a TIMEOUT is reported as UNKNOWN rather
/// than as failure, and nothing here offers "try again".
///
/// ── NOT FIRED ──
///
/// Built, wired, and never sent. Publishing to other tenants is the
/// owner's act, the same standing decision as `createInquiry`.
struct NewListingView: View {
    let onPosted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var side: ExchangeSide = .sell
    @State private var kind: ExchangeKind = .culture
    @State private var commodity = "wheat"
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var regionCode = ""
    @State private var descriptionText = ""
    @State private var sellerDisplayName = ""
    @State private var sellerContact = ""
    @State private var hasExpiry = false
    @State private var expiresAt = Date().addingTimeInterval(60 * 60 * 24 * 30)

    @State private var sending = false
    @State private var failure: Failure?

    private enum Failure: Equatable {
        case refused(String)
        case unknown(String)
    }

    /// Both accept a comma or a full stop. A Bulgarian keyboard produces
    /// "12,5" and the wire wants 12.5; this device also reports en_BG, so
    /// neither separator can be assumed.
    private func decimal(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: WireDecimal.wireLocale)
    }

    private var draft: CreateExchangeListing? {
        guard let quantity = decimal(quantityText) else { return nil }
        return CreateExchangeListing(
            side: side.rawValue,
            kind: kind.rawValue,
            commodity: commodity,
            quantityTonnes: quantity,
            pricePerTonne: decimal(priceText),
            regionCode: regionCode.trimmingCharacters(in: .whitespaces),
            description: descriptionText.isEmpty ? nil : descriptionText,
            sellerDisplayName: sellerDisplayName.isEmpty ? nil : sellerDisplayName,
            sellerContact: sellerContact.isEmpty ? nil : sellerContact,
            expiresAt: hasExpiry
                ? expiresAt.formatted(.iso8601.year().month().day()
                    .dateSeparator(.dash).timeSeparator(.colon)
                    .timeZone(separator: .omitted))
                : nil
        )
    }

    private var canSend: Bool {
        guard !sending, let draft else { return false }
        // A future expiry is a server rule, mirrored: the schema refuses a
        // past one, and learning that after a request that cannot be
        // retried is the wrong order.
        if hasExpiry && expiresAt <= Date() { return false }
        return draft.problems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Страна", selection: $side) {
                        ForEach(ExchangeSide.allCases.filter { $0 != .unknown }, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    Picker("Вид", selection: $kind) {
                        ForEach(ExchangeKind.allCases.filter { $0 != .unknown }, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    // A PICKER, not a text field. `commodity` transforms
                    // through `normalizeCommodity` server-side and a miss
                    // is a 400 quoting the whole canonical list — and the
                    // web's own modal maps the same array to its options,
                    // so driving both from one set is what makes them
                    // incapable of drifting. It also stops the phone
                    // posting a slug the board cannot filter on.
                    Picker("Култура", selection: $commodity) {
                        ForEach(Self.canonicalCommodities, id: \.self) { slug in
                            Text(CommodityName.canonical(slug) ?? slug).tag(slug)
                        }
                    }
                }

                Section("Количество и цена") {
                    LabeledContent("Тонове") {
                        TextField("0", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Цена / т") {
                        TextField("по избор", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    // NO CURRENCY PICKER. `priceCurrency` is a
                    // `z.literal('EUR')` — the exchange is single-currency
                    // by design and used to accept BGN and USD before
                    // being deliberately narrowed. Offering a choice that
                    // does not exist would be a 400 dressed as a feature.
                    LabeledContent("Валута") {
                        Text("EUR").foregroundStyle(.secondary)
                    }
                }

                Section("Регион") {
                    TextField("напр. BG-PVN", text: $regionCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Описание") {
                    TextEditor(text: $descriptionText).frame(minHeight: 90)
                }

                Section {
                    TextField("Име за показване", text: $sellerDisplayName)
                    TextField("Контакт", text: $sellerContact)
                } header: {
                    Text("Продавач")
                } footer: {
                    // Said on the screen, because the server keeping it
                    // private does not stop an operator assuming it is
                    // public and declining to fill it in.
                    Text("Контактът НЕ се показва в обявата. Разкрива се само на купувач, чието запитване приемете.")
                }

                Section {
                    Toggle("Срок на валидност", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Валидна до", selection: $expiresAt,
                                   in: Date()..., displayedComponents: .date)
                    }
                }

                if let problem = problemText { Section { Text(problem).font(.footnote).foregroundStyle(.secondary) } }
                if let failure { Section { failureView(failure) } }
            }
            .inlineTitle("Нова обява")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Публикувай") { Task { await post() } }.disabled(!canSend)
                    }
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    @ViewBuilder
    private func failureView(_ failure: Failure) -> some View {
        switch failure {
        case .refused(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(Palette.error)
                Text("Обявата НЕ е публикувана.").font(.footnote).foregroundStyle(.secondary)
            }
        case .unknown(let message):
            // No retry button, deliberately. A second attempt after a lost
            // response is how one offer becomes two on a board every
            // tenant can see.
            VStack(alignment: .leading, spacing: 6) {
                Label("Неясен резултат", systemImage: "questionmark.circle")
                    .foregroundStyle(Palette.error)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Text("""
                    Връзката прекъсна, преди сървърът да отговори. Обявата може \
                    да е публикувана. Проверете „Моите обяви“, преди да я \
                    въведете отново — повторното публикуване създава втора обява, \
                    видима за всички стопанства.
                    """)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var problemText: String? {
        guard !quantityText.isEmpty else { return nil }
        guard let draft else { return "Количеството не е разчетено." }
        if hasExpiry && expiresAt <= Date() { return "Срокът трябва да е в бъдещето." }
        switch draft.problems.first {
        case .quantityOutOfRange: return "Количеството трябва да е между 0 и 1 000 000 т."
        case .priceOutOfRange: return "Цената е извън допустимия диапазон."
        case .regionMissing: return "Регионът е задължителен."
        case .expiryInThePast: return "Срокът трябва да е в бъдещето."
        case nil: return nil
        }
    }

    private func post() async {
        guard let draft, !sending else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            _ = try await ExchangeAPI.createListing(draft)
            onPosted()
            dismiss()
        } catch let error as URLError {
            failure = .unknown(UserMessage.text(for: error))
        } catch {
            failure = .refused(UserMessage.text(for: error))
        }
    }

    /// The canonical ten, in the order a Bulgarian grain farm meets them.
    /// The input commodities (`diesel`, `urea`, …) are NOT here: they are
    /// in the same slug space and are not things a farm posts a tonnage of
    /// on this board.
    static let canonicalCommodities = [
        "wheat", "maize", "barley", "sunflower", "rapeseed",
        "oats", "rye", "soybean", "peas", "lentils",
    ]
}
