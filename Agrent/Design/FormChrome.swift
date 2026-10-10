import SwiftUI

// The text a List or a Form draws around its rows — section headers and
// footers, a row's value, a field's prompt, a menu picker's value — in token
// colours rather than the system's greys (agrent-ios#159), and laid out so a
// Bulgarian value is never cut short (#160).
//
// WHY THIS IS A FILE OF ITS OWN. #156 put every form and list on token
// SURFACES, and the system kept drawing its own text on them:
// `secondaryLabel` headers at 3.29:1 on the light page and 4.25:1 in
// «Слънце», and `placeholderText` prompts at about 1.9:1 on the light card.
// Those are fixed here once, and `ListChromeTests` fails on a `Section("…")`,
// a header or footer closure, a `TextField` without a styled prompt, or a
// `LabeledContent`, anywhere outside this file — so the next form cannot
// bring the greys back. Every colour is a `Palette.ListChrome` role, and
// every pair is measured in `PaletteTokenTests`.
//
// The pickers are here for the same reason: `MenuPicker` for a short list,
// `PagePicker` for a long one, and no `.pickerStyle(.navigationLink)` —
// the page it pushes is the system's, on its grouped grey (#164), and
// `ListChromeTests` fails on one.

// MARK: - Section headers and footers

/// A section's header in `Palette.ListChrome.header`.
///
/// The system draws a header in `secondaryLabel` unless the header view says
/// otherwise; an explicit `foregroundStyle` is the documented way to say so,
/// and it survives an OS update that a container-wide trick might not.
struct SectionHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.foregroundStyle(Palette.ListChrome.header)
    }
}

extension SectionHeader where Content == Text {
    init(_ title: String) {
        self.init { Text(title) }
    }
}

/// A section's footer in `Palette.ListChrome.header`. A footer that writes a
/// caveat in `Palette.warning` keeps it: an explicit style inside wins over
/// this one.
struct SectionFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.foregroundStyle(Palette.ListChrome.header)
    }
}

extension SectionFooter where Content == Text {
    init(_ text: String) {
        self.init { Text(text) }
    }
}

extension Section where Parent == Text, Content: View, Footer == EmptyView {
    /// `Section("…")` with its header in the token colour.
    ///
    /// The header is a `Text`, not a `SectionHeader`, so the same call also
    /// works inside a `Menu` or a `Picker`, where a section title must be
    /// text (UIKit draws those, and ignores the colour).
    init(titled title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            Text(title).foregroundStyle(Palette.ListChrome.header)
        }
    }
}

// MARK: - Field prompts

extension Text {
    /// A `TextField`'s placeholder in `Palette.ListChrome.placeholder`:
    ///
    ///     TextField("Сума", text: $amount, prompt: .fieldPrompt("Сума"))
    ///
    /// Without a prompt, a field shows its title in UIKit's
    /// `placeholderText` — about 1.9:1 on the light card. The title stays
    /// what VoiceOver and Voice Control call the field.
    static func fieldPrompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Palette.ListChrome.placeholder)
    }
}

extension View {
    /// Room for the whole of a vertical field's prompt — see `PromptRoom`:
    ///
    ///     TextField("Заглавие", text: $title,
    ///               prompt: .fieldPrompt(example), axis: .vertical)
    ///         .promptRoom(example)
    ///
    /// `atMost` caps what TYPING may grow the field to — a composer pinned
    /// under a conversation must not grow over it — and never cuts the
    /// prompt: the cap rises to the prompt's own lines when it needs more.
    func promptRoom(_ prompt: String, atMost: Int? = nil) -> some View {
        modifier(PromptRoom(prompt: prompt, atMost: atMost))
    }
}

/// Gives a `TextField(axis: .vertical)` as many lines as its prompt needs,
/// so a long prompt wraps instead of being cut (#164).
///
/// ── The defect ──
///
/// A vertical field draws its prompt in a label exactly as tall as the
/// field, and an empty field is one line tall. So a prompt longer than a
/// line is cut, however readily the field wraps what is TYPED: at AX5
/// «Нов запис» read «напр. Трети…». Measured in a form hosted at the
/// iPhone 17 Pro's width (iOS 26.5 simulator): 53 pt type, 767 pt of prompt
/// in a 338 pt row, and a label that already allows any number of lines —
/// it was one line HIGH, not one line long. It was cut from xxxLarge up,
/// not only at the accessibility sizes.
///
/// ── The fix ──
///
/// `lineLimit(n...)`: at least n lines, and still growing as the farmer
/// types. n is MEASURED rather than looked up by text size, because it
/// depends on the width as much as the size — at xxxLarge the same prompt
/// takes two lines on that phone and one on a 440 pt one, at AX5 four and
/// three. Two hidden texts are laid out in the field's own width, the
/// prompt and a single line, and n is the ratio of their heights. At the
/// default size the prompt fits, n is 1, and the field is what it was.
/// Checked the same way, hosted at 375, 402 and 440 pt from Large to AX5:
/// the prompt's label had the height its text needs at every one.
struct PromptRoom: ViewModifier {
    let prompt: String
    var atMost: Int? = nil

    @State private var promptHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0

    private var lines: Int {
        guard lineHeight > 0 else { return 1 }
        // A hair under, so a rounding error in the layout cannot turn a
        // three-line prompt into four lines of room.
        return max(1, Int((promptHeight / lineHeight - 0.05).rounded(.up)))
    }

    func body(content: Content) -> some View {
        Group {
            if let atMost {
                content.lineLimit(lines...max(lines, atMost))
            } else {
                content.lineLimit(lines...)
            }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                measured(Text(prompt), into: $promptHeight)
                measured(Text(verbatim: "Х"), into: $lineHeight)
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    /// `text` wrapped in the width it is given, its height written back.
    private func measured(_ text: Text, into height: Binding<CGFloat>) -> some View {
        text
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { height.wrappedValue = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, new in height.wrappedValue = new }
                }
            }
    }
}

// MARK: - Rows

/// A label and the value it names — what `LabeledContent` is, with the value
/// in `Palette.ListChrome.value` instead of `secondaryLabel` (3.34:1 on the
/// light card).
///
/// Only the DEFAULT colour changes: a value that is a success, a caveat or
/// emphasised `Color.primary` says so itself, and that wins. The layout is
/// still `LabeledContent`'s, which puts the value under its label at the
/// accessibility sizes.
struct ValueRow<Label: View, Value: View>: View {
    @ViewBuilder var value: Value
    @ViewBuilder var label: Label

    var body: some View {
        LabeledContent {
            value.foregroundStyle(Palette.ListChrome.value)
        } label: {
            label
        }
    }
}

extension ValueRow where Label == Text {
    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.init(value: value) { Text(title) }
    }
}

/// A label and a text field the farmer types into, on one row — «Тонове»,
/// «Количество». The TYPED text is `Palette.Field.text`, not the grey
/// `LabeledContent` gives a value: it is the farmer's input, not a hint.
struct FieldRow<Field: View>: View {
    let title: String
    /// What VoiceOver says for the field when the title alone does not tell
    /// it from its neighbours — six rows titled «EUR / дка» on one sheet.
    /// Voice Control still answers to the visible title.
    let spoken: String?
    @ViewBuilder var field: Field

    init(_ title: String, spoken: String? = nil, @ViewBuilder field: () -> Field) {
        self.title = title
        self.spoken = spoken
        self.field = field()
    }

    var body: some View {
        LabeledContent {
            field
                .foregroundStyle(Palette.Field.text)
                // The row's title is what the field IS. A field's own title
                // here is its hint («0», «по избор»), and VoiceOver read that
                // as its name; Voice Control could not name it at all.
                .accessibilityLabel(spoken ?? title)
                .accessibilityInputLabels(A11y.spokenNames(title))
        } label: {
            Text(title)
        }
    }
}

// MARK: - Menu pickers

/// A menu picker whose collapsed value is drawn by SwiftUI, so it wraps
/// instead of being cut (#160).
///
/// ── The defect ──
///
/// `Picker` in a `Form`, with no style, is a menu picker, and its collapsed
/// value is a UIKit button. In «Нов запис» it drew «Дейност» as «Де…ст» in a
/// row more than half empty, at the DEFAULT text size — the same
/// measure-before-substitution shape `BulgarianLayout` describes, in a
/// control that priming does not reach. «Препарат за РЗ» had already clipped
/// to «Препа…за РЗ» on the product form, which went to `.navigationLink` for
/// it; that pushed a system-styled list, so it was not the answer anywhere
/// (#164) — a long list of options is a `PagePicker` instead.
///
/// ── The fix ──
///
/// The same `Picker`, inside a `Menu` whose label is a SwiftUI `Text`. The
/// menu that opens is unchanged (the options, the check mark), and the value
/// in the row is ordinary text: it wraps at any width, and at the
/// accessibility sizes the row stacks — label above, value under it at full
/// width — decided from the size, as `AdaptiveRow` does, rather than from a
/// measurement.
///
/// ── Accessibility ──
///
/// One element, as the system picker is: the menu button, labelled with the
/// row's title and valued with the selection («Тип, Дейност»). The visible
/// title is hidden so it is not a second stop. Voice Control answers to the
/// title, Cyrillic first, and to `english` when given.
struct MenuPicker<Selection: Hashable, Options: View>: View {
    private let title: String
    private let english: String?
    @Binding private var selection: Selection
    private let value: String
    private let options: Options

    @Environment(\.dynamicTypeSize) private var typeSize

    /// `value` is what the row shows for the current selection — the label
    /// of the option that is chosen, which only the call site knows.
    init(_ title: String, english: String? = nil, selection: Binding<Selection>, value: String,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self.english = english
        _selection = selection
        self.value = value
        self.options = options()
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        // `AnyLayout`, as in `MetaRow`, so the menu keeps its identity when
        // the text size changes with the form open.
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        layout {
            Text(title)
                // The title first: it is short, and it is the one that must
                // be whole. The value takes the rest and wraps in it.
                .layoutPriority(1)
                .accessibilityHidden(true)
            Menu {
                Picker(title, selection: $selection) { options }
                    .pickerStyle(.inline)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .multilineTextAlignment(stacked ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Palette.ListChrome.menuValue)
                .frame(maxWidth: .infinity, alignment: stacked ? .leading : .trailing)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityInputLabels(A11y.spokenNames(title, english))
        }
    }
}

// MARK: - Pushed pickers

/// One option of a `PagePicker`: the value it selects and what the row says.
struct PickerChoice<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// A run of `PickerChoice`s under an optional section title — «Култури»,
/// «Рискове».
struct PickerChoiceSection<Value: Hashable> {
    let title: String?
    let choices: [PickerChoice<Value>]
}

/// A picker that pushes its options onto a page of their own, as
/// `.pickerStyle(.navigationLink)` does, with that page on the token
/// surfaces (#164).
///
/// ── The defect ──
///
/// `.navigationLink` pushes a List the SYSTEM builds, on
/// `systemGroupedBackground` — black in dark mode under a green app, the
/// grey #156 took off every other screen. Nothing reaches it: the pushed
/// list is not in the view tree a modifier can be applied to, and
/// `PageForm`'s `Group { … }.cardRow()` stops at the row that pushes.
///
/// ── Which pickers are this, and which are `MenuPicker` ──
///
/// A menu for a short, fixed set of options — the four crops, the seven
/// product kinds, a tenant's ten units. This for a list that is LONG or
/// UNBOUNDED, or whose labels are long enough that a menu would cut them:
/// a location's parcels, an insurer's catalogue of products. The farmer
/// reads each option at full width, on its own page, as before.
///
/// ── Behaviour ──
///
/// The same as the system page: the chosen row carries a check mark,
/// choosing one goes back. The row that pushes shows the selection in
/// `Palette.ListChrome.value`, wrapping, and stacks under its title at the
/// accessibility sizes, as `MenuPicker` does.
///
/// ── Accessibility ──
///
/// The pushing row is one element, «Парцел, Южен блок», a button that
/// Voice Control answers to by the title. On the page each option is a
/// button whose name is its label, and the chosen one carries
/// `.isSelected` — what VoiceOver says for the system's check mark.
struct PagePicker<Selection: Hashable>: View {
    private let title: String
    private let english: String?
    @Binding private var selection: Selection
    private let value: String
    private let sections: [PickerChoiceSection<Selection>]

    @Environment(\.dynamicTypeSize) private var typeSize

    /// `value` is what the row shows for the current selection, as for
    /// `MenuPicker`.
    init(_ title: String, english: String? = nil, selection: Binding<Selection>, value: String,
         sections: [PickerChoiceSection<Selection>]) {
        self.title = title
        self.english = english
        _selection = selection
        self.value = value
        // A run with nothing in it would be a title over no rows — a
        // catalogue with no perils, say — so it is left out.
        self.sections = sections.filter { !$0.choices.isEmpty }
    }

    /// One untitled run of options.
    init(_ title: String, english: String? = nil, selection: Binding<Selection>, value: String,
         choices: [PickerChoice<Selection>]) {
        self.init(title, english: english, selection: selection, value: value,
                  sections: [PickerChoiceSection(title: nil, choices: choices)])
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        NavigationLink {
            PagePickerList(title: title, selection: $selection, sections: sections)
        } label: {
            layout {
                Text(title).layoutPriority(1)
                Text(value)
                    .foregroundStyle(Palette.ListChrome.value)
                    .multilineTextAlignment(stacked ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: stacked ? .leading : .trailing)
            }
        }
        // The link is already one element, a button; these replace the
        // two texts it would read with the title and the selection, as the
        // system's own picker row reads.
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityInputLabels(A11y.spokenNames(title, english))
    }
}

/// The page a `PagePicker` pushes: a list on the page colour, as every
/// list in the app is (`pageBackground()`, `pageRow()`).
private struct PagePickerList<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let sections: [PickerChoiceSection<Selection>]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let heading = section.title {
                    Section(titled: heading) { rows(section.choices) }
                        .pageRow()
                } else {
                    Section { rows(section.choices) }
                        .pageRow()
                }
            }
        }
        .pageBackground()
        .inlineTitle(title)
    }

    private func rows(_ choices: [PickerChoice<Selection>]) -> some View {
        ForEach(choices) { choice in
            let chosen = choice.value == selection
            Button {
                choose(choice.value)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(choice.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The check mark is hidden; this is what it says. No input
            // label: an option is DATA (a parcel's name, an insurer's
            // product), and Voice Control answers to the visible text.
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }

    /// Choosing goes back, as the system's page does: the choice is made,
    /// and the form is where the farmer was going.
    private func choose(_ value: Selection) {
        selection = value
        dismiss()
    }
}
