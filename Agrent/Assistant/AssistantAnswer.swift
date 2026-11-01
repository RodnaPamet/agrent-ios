import SwiftUI

/// The assistant's answer as BLOCKS: paragraphs, headings, lists and tables
/// (owner, 2026-11-01: "this | delimiter does not show well - answers need
/// to be better structured").
///
/// The model writes Markdown, and SwiftUI's `Text` draws only its inline
/// part (bold, italics), so a table reached the person as rows of «|» and
/// «|---|---|». This reads the block structure the model actually uses and
/// draws each block as the phone draws the same thing elsewhere: a two-
/// column table as label-and-value rows, a wider one as a card per row
/// whose first cell is its title, a list with its marks, a heading in the
/// house heading style. Anything not recognised stays a paragraph, so a
/// shape this does not know costs formatting, never words.
enum AssistantAnswer {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case bullets([String])
        case numbered([String])
        /// The header's cells, then each row's; rows as wide as the header.
        case table(header: [String], rows: [[String]])
        /// `---`, `***` or `___` on its own line: a rule between parts, which
        /// reached the owner's screen as a row of dashes (2026-11-01).
        case divider
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                index += 1
            } else if isRule(line) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
            } else if line.hasPrefix("|") {
                flushParagraph()
                var tableLines: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    tableLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(table(tableLines))
            } else if let heading = heading(line) {
                flushParagraph()
                blocks.append(.heading(heading))
                index += 1
            } else if bullet(line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let item = bullet(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bullets(items))
            } else if numbered(line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let item = numbered(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numbered(items))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    /// `| a | b |` rows; the `|---|---|` rule under the header is dropped.
    /// Short rows are padded and long ones cut to the header's width, so a
    /// row the model got wrong still lines up. No rule means no header: the
    /// first row is a row like the rest, under an empty header.
    private static func table(_ lines: [String]) -> Block {
        let rows = lines.map(cells)
        let isRule: ([String]) -> Bool = { cells in
            !cells.isEmpty && cells.allSatisfy { $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }
        }
        let header: [String]
        var body: [[String]]
        if rows.count >= 2, isRule(rows[1]) {
            header = rows[0]
            body = Array(rows.dropFirst(2))
        } else {
            header = Array(repeating: "", count: rows.map(\.count).max() ?? 0)
            body = rows
        }
        body = body.filter { !isRule($0) }.map { row in
            Array((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count))
        }
        return .table(header: header, rows: body)
    }

    /// Three or more of one of `-`, `*`, `_`, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func cells(_ line: String) -> [String] {
        var inner = line
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) {
            return String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        // One or two digits: «2026. Годината…» is a sentence, not item 2026.
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              (1...2).contains(line[..<dot].count), line[..<dot].allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The answer as words, for VoiceOver: no Markdown marks, no pipes, a
    /// table row as its cells.
    static func spoken(_ text: String) -> String {
        blocks(text).map { block -> String in
            switch block {
            case .paragraph(let words), .heading(let words):
                return plain(words)
            case .bullets(let items), .numbered(let items):
                return items.map(plain).joined(separator: ". ")
            case .table(_, let rows):
                return rows.map { $0.map(plain).filter { !$0.isEmpty }.joined(separator: ", ") }.joined(separator: ". ")
            case .divider:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    static func plain(_ markdown: String) -> String {
        String(AssistantRendering.answer(markdown).characters)
    }
}

/// The blocks, drawn.
struct AssistantAnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AssistantAnswer.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AssistantText.answered(AssistantAnswer.spoken(text)))
    }

    @ViewBuilder
    private func view(_ block: AssistantAnswer.Block) -> some View {
        switch block {
        case .paragraph(let words):
            inline(words).font(.body)
        case .heading(let words):
            inline(words).font(.headline)
        case .bullets(let items):
            list(items.map { ("•", $0) })
        case .numbered(let items):
            list(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ markdown: String) -> some View {
        Text(AssistantRendering.answer(markdown))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func list(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.0).foregroundStyle(Palette.secondaryText)
                    inline(item.1)
                }
                .font(.body)
            }
        }
    }

    /// Two columns: label and value, like a fact row. More: a card per row,
    /// its first cell the title, the rest «header: value» under it. Either
    /// way it reads at any text size, where a grid of narrow columns would
    /// break every word.
    @ViewBuilder
    private func table(header: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if header.count == 2, header.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .firstTextBaseline) {
                    inline(header[0])
                    Spacer(minLength: 12)
                    inline(header[1])
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .padding(.bottom, 4)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                if row.count == 2 {
                    HStack(alignment: .firstTextBaseline) {
                        inline(row[0])
                        Spacer(minLength: 12)
                        inline(row[1]).font(.body.monospacedDigit()).multilineTextAlignment(.trailing)
                    }
                    .font(.body)
                    .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = row.first { inline(title).font(.body.weight(.semibold)) }
                        ForEach(Array(row.dropFirst().enumerated()), id: \.offset) { column, cell in
                            if !cell.isEmpty {
                                let name = header.indices.contains(column + 1) ? header[column + 1] : ""
                                inline(name.isEmpty ? cell : "\(name): \(cell)")
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.Surface.edge, lineWidth: 1) }
    }
}
