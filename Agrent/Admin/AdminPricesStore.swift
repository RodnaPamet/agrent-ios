import Foundation
import Observation

/// Админ → «Цени» (#258): the superuser's day of prices, and the API's beside
/// them.
///
/// Network only, never `ResponseCache`. Admin data never touches the disk
/// (CLAUDE.md), and a stale copy of what is overriding every farm's prices is
/// worse than a spinner.
@Observable
@MainActor
final class AdminPricesStore {
    private(set) var state: LoadState<AdminPricesAPI.Overrides> = .loading

    /// The day the prices are FOR. Today unless changed, so yesterday's
    /// missed entry can still be made. The server's rule is that the latest
    /// DAY wins, not the latest write: a correction to yesterday made today
    /// does not beat today's figure.
    var day = Calendar.current.startOfDay(for: Date())

    /// What is typed per commodity, as typed: «212,50», spaces and either
    /// decimal mark. Empty means "not today", never zero.
    var texts: [String: String] = [:]

    private(set) var saving = false
    /// The commodity whose override is being cleared.
    private(set) var clearing: String?
    private(set) var failure: String?
    /// Said once a save lands: how many prices went in, and for which day.
    private(set) var savedNote: String?

    /// One per presentation of the screen. The key for a save is minted from
    /// this and the day's content (`CostIdempotencyKey.mint`), so a retry of
    /// the same sheet dedupes on the server and a corrected one does not.
    @ObservationIgnored private let nonce = UUID().uuidString

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await AdminPricesAPI.load(), .fresh)
        } catch {
            if state.value == nil { state = .failed(UserMessage.text(for: error)) }
            else { failure = UserMessage.text(for: error) }
        }
    }

    // MARK: - The rows, in the form's order

    /// The five crops, then the inputs, in the owner's order. A commodity
    /// the server lists and this build does not know joins the second run.
    var cropRows: [AdminPricesAPI.Overrides.Row] { rows(AdminPricesAPI.crops) }

    var inputRows: [AdminPricesAPI.Overrides.Row] {
        let known = Set(AdminPricesAPI.crops + AdminPricesAPI.inputs)
        let extra = (state.value?.commodities ?? []).filter { !known.contains($0.commodity) }
        return rows(AdminPricesAPI.inputs) + extra
    }

    private func rows(_ order: [String]) -> [AdminPricesAPI.Overrides.Row] {
        let all = state.value?.commodities ?? []
        return order.compactMap { slug in all.first { $0.commodity == slug } }
    }

    // MARK: - What would be sent

    enum Problem: Equatable {
        /// Not a number at all.
        case unreadable
        /// Zero or less. A price of 0 would value every farm's crop at
        /// nothing; the screen refuses it rather than let a slip do that.
        case notPositive
    }

    /// Per commodity: the problem with what is typed, if any. Blank fields
    /// are not problems; they are left out of the day.
    var problems: [String: Problem] {
        var found: [String: Problem] = [:]
        for (commodity, text) in texts where !Self.isBlank(text) {
            guard let value = OverheadSheet.amount(text) else { found[commodity] = .unreadable; continue }
            if value <= 0 { found[commodity] = .notPositive }
        }
        return found
    }

    /// The day as it would be sent: every field with a readable, positive
    /// figure, in the form's order.
    var draft: AdminPricesAPI.Day {
        let order = AdminPricesAPI.crops + AdminPricesAPI.inputs
        let typed = texts.compactMap { commodity, text -> AdminPricesAPI.Day.Price? in
            guard let value = OverheadSheet.amount(text), value > 0 else { return nil }
            return .init(commodity: commodity, value: value)
        }
        let sorted = typed.sorted {
            (order.firstIndex(of: $0.commodity) ?? .max, $0.commodity)
                < (order.firstIndex(of: $1.commodity) ?? .max, $1.commodity)
        }
        return AdminPricesAPI.Day(date: BgDate.isoDay(day), prices: sorted)
    }

    var canSave: Bool { !saving && problems.isEmpty && !draft.prices.isEmpty }

    /// A figure far from the API's latest, worth a second look before it
    /// replaces the price every farm sees: a slipped digit, or a diesel price
    /// typed per 1000 l where the field is per litre. Said, not refused; the
    /// market can move.
    func isFarFromAPI(_ row: AdminPricesAPI.Overrides.Row) -> Bool {
        guard let text = texts[row.commodity], let typed = OverheadSheet.amount(text), typed > 0,
              let api = row.api, api.value.value > 0,
              let factor = Self.factor(from: row.entryUnit, to: api.unit) else { return false }
        let ratio = typed * factor / api.value.value
        return ratio > 1.5 || ratio < Decimal(2) / Decimal(3)
    }

    /// What one typed unit is in the API's unit, where the two are exactly
    /// related; nil where they are not. EUR/l against the Oil Bulletin's
    /// EUR/1000l is ×1000, which is the diesel slip worth catching. EUR/t
    /// against the World Bank's USD/mt has no rate here, so it is not
    /// compared at all rather than compared wrongly.
    static func factor(from typed: String, to api: String) -> Decimal? {
        if typed == api { return 1 }
        if typed == "EUR/l", api == "EUR/1000l" { return 1000 }
        return nil
    }

    // MARK: - Writing

    func save() async {
        guard canSave else { return }
        let day = draft
        saving = true
        failure = nil
        savedNote = nil
        defer { saving = false }
        do {
            let written = try await AdminPricesAPI.save(day, key: CostIdempotencyKey.mint(nonce: nonce, draft: day))
            texts = [:]
            savedNote = "Записани " + Plural.bg(written.written, "цена", "цени")
                + " за " + BgDate.rowDay(self.day) + "."
            await load()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    func clear(_ commodity: String) async {
        clearing = commodity
        failure = nil
        savedNote = nil
        defer { clearing = nil }
        do {
            try await AdminPricesAPI.clear(commodity)
            await load()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }

    // MARK: - Words

    /// The unit as a Bulgarian reader writes it.
    static func unitLabel(_ unit: String) -> String {
        switch unit {
        case "EUR/t": "€/т"
        case "EUR/l": "€/л"
        case "EUR/1000l": "€/1000 л"
        case "USD/mt": "$/т"
        default: unit
        }
    }

    /// A commodity as a Bulgarian reader names it: «Пшеница», «Уреа
    /// (карбамид)», «Нафта (дизелово гориво)». Canonical slugs, so the
    /// closed-set table; an unknown one is title-cased, never shown raw.
    static func name(_ commodity: String) -> String {
        CommodityName.canonical(commodity) ?? commodity
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
