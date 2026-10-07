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
    @ViewBuilder var field: Field

    init(_ title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        LabeledContent {
            field
                .foregroundStyle(Palette.Field.text)
                // The row's title is what the field IS. A field's own title
                // here is its hint («0», «по избор»), and VoiceOver read that
                // as its name; Voice Control could not name it at all.
                .accessibilityLabel(title)
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
/// it; that pushes a system-styled list, so it is not the answer everywhere.
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
