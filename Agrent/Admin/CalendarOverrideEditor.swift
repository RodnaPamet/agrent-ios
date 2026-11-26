import SwiftUI

/// Correct a calendar window, or add one (agri-saas#3095). The basis is
/// required and replaces the source: the window then shows «Коригирано от
/// Agrent» and the basis, never МЗХ's citation.
struct CalendarOverrideEditor: View {
    let target: CalendarOverrideTarget
    let cropTitle: String
    let saved: () async -> Void

    @State private var draft: CalendarOverridesAPI.WindowDraft
    @State private var basis: String
    @State private var titleText: String
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(target: CalendarOverrideTarget, cropTitle: String, saved: @escaping () async -> Void) {
        self.target = target
        self.cropTitle = cropTitle
        self.saved = saved
        let start: CalendarOverridesAPI.WindowDraft
        var basis = ""
        switch target {
        case .override(let o):
            start = o.window
            basis = o.basis.bg
        case .correct(_, let w):
            start = w
        case .add(let crop):
            start = .init(id: CalendarOverridesText.newID(crop: crop), kind: "sowing", band: "optimal",
                          region: "both", from: "03-01", to: "03-31", title: nil)
        }
        _draft = State(initialValue: start)
        _basis = State(initialValue: basis)
        _titleText = State(initialValue: start.title?.bg ?? "")
    }

    /// A new window may choose its kind; a correction keeps the window's.
    private var isNew: Bool {
        if case .add = target { return true }
        if case .override(let o) = target { return o.isAddition }
        return false
    }

    private var problem: String? {
        if draft.kind == "sowing" && draft.band == nil { return CalendarOverridesText.needsBand }
        if basis.recorded == nil { return CalendarOverridesText.needsBasis }
        return nil
    }

    var body: some View {
        NavigationStack {
            PageForm {
                Section {
                    if isNew {
                        MenuPicker(CalendarOverridesText.kindLabel, selection: $draft.kind,
                                   value: CalendarOverridesText.kind(draft.kind, band: nil)) {
                            ForEach(["sowing", "fieldwork", "harvest"], id: \.self) {
                                Text(CalendarOverridesText.kind($0, band: nil)).tag($0)
                            }
                        }
                        TextField(CalendarOverridesText.titleLabel, text: $titleText,
                                  prompt: .fieldPrompt(CalendarOverridesText.titlePrompt))
                    } else {
                        ValueRow(CalendarOverridesText.kindLabel) {
                            Text(CalendarOverridesText.kind(draft.kind, band: nil))
                        }
                    }
                    if draft.kind == "sowing" {
                        MenuPicker(CalendarOverridesText.bandLabel, selection: $draft.band,
                                   value: AgroWords.band(draft.band) ?? "") {
                            ForEach(["early", "optimal", "late"], id: \.self) {
                                Text(AgroWords.band($0) ?? $0).tag(Optional($0))
                            }
                        }
                    }
                    MenuPicker(CalendarOverridesText.regionLabel, selection: $draft.region,
                               value: CalendarOverridesText.region(draft.region)) {
                        ForEach(["both", "north", "south"], id: \.self) {
                            Text(CalendarOverridesText.region($0)).tag($0)
                        }
                    }
                } header: {
                    SectionHeader(cropTitle)
                }
                Section {
                    MonthDayPicker(label: CalendarOverridesText.fromLabel, value: $draft.from)
                    MonthDayPicker(label: CalendarOverridesText.toLabel, value: $draft.to)
                } header: {
                    SectionHeader(CalendarOverridesText.datesLabel)
                } footer: {
                    SectionFooter(CalendarOverridesText.datesHint)
                }
                Section {
                    TextField(CalendarOverridesText.basisLabel, text: $basis,
                              prompt: .fieldPrompt(CalendarOverridesText.basisPrompt), axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    SectionHeader(CalendarOverridesText.basisLabel)
                } footer: {
                    SectionFooter(CalendarOverridesText.basisHint)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(Palette.error) }
                }
            }
            .inlineTitle(isNew ? CalendarOverridesText.addWindow : CalendarOverridesText.correctTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                        .disabled(saving)
                        .accessibilityInputLabels(A11y.Spoken.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") { Task { await save() } }
                        .disabled(problem != nil || saving)
                        .accessibilityHint(problem ?? "")
                        .accessibilityInputLabels(A11y.Spoken.save)
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: draft.kind) {
                // A band belongs to sowing only.
                if draft.kind != "sowing" { draft.band = nil } else if draft.band == nil { draft.band = "optimal" }
            }
        }
    }

    private func save() async {
        guard problem == nil, !saving, let words = basis.recorded else { return }
        saving = true
        failure = nil
        defer { saving = false }
        var window = draft
        if isNew { window.title = titleText.recorded.map(CalendarOverridesAPI.Words.init(bg:)) }
        do {
            try await CalendarOverridesAPI.set(cropKey: target.cropKey, window: window, basis: words)
            await saved()
            dismiss()
        } catch {
            failure = UserMessage.text(for: error)
        }
    }
}

/// A day of the year with no year: month, then a day that exists in it.
private struct MonthDayPicker: View {
    let label: String
    @Binding var value: String

    private var month: Int { Int(value.prefix(2)) ?? 1 }
    private var day: Int { Int(value.suffix(2)) ?? 1 }
    private static let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Picker(label, selection: Binding(get: { day }, set: { set(month, $0) })) {
                ForEach(1...Self.lengths[month - 1], id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Picker(label, selection: Binding(get: { month }, set: { set($0, day) })) {
                ForEach(1...12, id: \.self) { Text(BgDate.monthName($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func set(_ month: Int, _ day: Int) {
        let clamped = min(day, Self.lengths[month - 1])
        value = String(format: "%02d-%02d", month, clamped)
    }
}

/// The console's words, in plain Bulgarian (owner, 2026-11-13).
enum CalendarOverridesText {
    static let title = "Календар: поправки"
    static let intro = "Поправка или нов срок важи за всички стопанства веднага. Вместо източник се пише основание, а срокът се показва с «Коригирано от Agrent»."
    static let empty = "Няма поправки. Всички срокове са по МЗХ."
    static let liveTitle = "В сила"
    static let new = "Нова поправка"
    static let pickCrop = "Изберете култура"
    static let addWindow = "Нов срок"
    static let correctWindow = "Поправи срок"
    static let correctTitle = "Поправка"
    static let corrected = "Поправен"
    static let added = "Добавен"
    static let remove = "Премахни"
    static let removeQuestion = "Да се премахне ли?"
    static let removeCorrection = "Срокът отново ще е по МЗХ."
    static let removeAddition = "Срокът ще изчезне от календара."
    static let editHint = "Отваря поправката"
    static let kindLabel = "Вид"
    static let bandLabel = "Срок за сеитба"
    static let regionLabel = "Област"
    static let datesLabel = "Срок"
    static let fromLabel = "От"
    static let toLabel = "До"
    static let datesHint = "Ако «До» е преди «От», срокът минава през Нова година."
    static let titleLabel = "Заглавие"
    static let titlePrompt = "например «Засаждане»"
    static let basisLabel = "Основание"
    static let basisPrompt = "например «НССЗ, Календар на земеделеца, март»"
    static let basisHint = "Защо срокът е различен от източника. Задължително."
    static let needsBand = "Изберете срок за сеитба: ранна, оптимален или късна."
    static let needsBasis = "Напишете основание."

    static func kind(_ kind: String, band: String?) -> String {
        if kind == "sowing", let band = AgroWords.band(band) { return band }
        switch kind {
        case "sowing": return AgroWords.sowing
        case "fieldwork": return AgroWords.works
        case "harvest": return AgroWords.harvest
        default: return kind
        }
    }

    static func region(_ region: String) -> String {
        switch region {
        case "north": AgroRegion.north.title
        case "south": AgroRegion.south.title
        default: "Цялата страна"
        }
    }

    /// A new window's id: the crop, `agrent`, the kind, and a short random tail —
    /// never one of МЗХ's ids, so the server reads it as an addition.
    static func newID(crop: String) -> String {
        "\(crop).agrent.\(UUID().uuidString.prefix(8).lowercased())"
    }
}
