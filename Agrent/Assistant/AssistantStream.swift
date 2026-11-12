import Foundation

/// The answer as it arrives (#587; agri-saas #2670), before the whole
/// `answer` replaces it.
///
/// ── Provisional, by contract ──
///
/// The server's final `answer` is authoritative: its text, links, proposal
/// and promotions. Everything here is shown only until it arrives, so a lost
/// part, a retry's duplicate, or a tool round that replaces a preamble can
/// never stay on screen.
///
/// ── A gap is not a restart ──
///
/// A gap in `seq` means a part was LOST: what is on screen stays, and nothing
/// more is added until `answer`, rather than drawing a hole. `restarted`
/// means what is on screen is now WRONG (the server retried and began
/// again): that part's text replaces it all, and counting starts from it.
///
/// ── Sentences, not Markdown ──
///
/// The server releases whole sentences, and a sentence can end inside an
/// unclosed `**`, a backtick span or a table row (backend 1, 2026-11-12: the
/// egress gate is a security control and deliberately reads no Markdown). So
/// `visible` holds back the unfinished end of the last line before it is
/// drawn.
struct AssistantStream: Equatable, Sendable {
    /// Everything received and placed, in order.
    private(set) var text = ""
    private var next = 0
    /// A part went missing: wait for `answer`.
    private(set) var stalled = false

    mutating func apply(_ part: String, seq: Int, restarted: Bool) {
        if restarted {
            text = part
            next = seq + 1
            stalled = false
            return
        }
        guard !stalled else { return }
        guard seq == next else {
            stalled = true
            return
        }
        text += part
        next = seq + 1
    }

    /// What may be drawn now: whole lines, and the last line up to any
    /// Markdown it has not closed yet. A table row is held until its line
    /// ends.
    var visible: String { Self.visible(text) }

    nonisolated static func visible(_ text: String) -> String {
        let head: Substring
        var tail: Substring
        if let newline = text.lastIndex(of: "\n") {
            head = text[...newline]
            tail = text[text.index(after: newline)...]
        } else {
            head = ""
            tail = text[...]
        }
        if tail.trimmingCharacters(in: .whitespaces).hasPrefix("|") { return String(head) }
        // An odd number of `**` leaves bold open: cut at the last one.
        if tail.components(separatedBy: "**").count.isMultiple(of: 2),
           let open = tail.range(of: "**", options: .backwards) {
            tail = tail[..<open.lowerBound]
        }
        if !tail.filter({ $0 == "`" }).count.isMultiple(of: 2), let open = tail.lastIndex(of: "`") {
            tail = tail[..<open]
        }
        return String(head + tail)
    }
}
