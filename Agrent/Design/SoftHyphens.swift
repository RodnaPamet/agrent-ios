import Foundation

/// Soft hyphens at the syllable breaks of the few words too long for a line
/// of large text at the accessibility sizes (#210).
///
/// At AX5 a word wider than the line is broken wherever the line runs out,
/// with no hyphen: the farm wizard drew «стопанство / то» and «Стопанств /
/// о с ЕИК». SwiftUI has no hyphenation setting, but the text system breaks
/// at a SOFT hyphen (U+00AD) when it must, and draws the hyphen only then.
/// So «стопан- / ството», and on a line wide enough, nothing changes.
///
/// DISPLAY ONLY. Every use sets the plain string as the accessibility label,
/// so VoiceOver, Voice Control and the UI tests read words, not code points.
///
/// A table, not a hyphenation algorithm: these are the words the A11yShots
/// AX5 captures showed breaking. A new one goes here when a capture shows it.
enum SoftHyphens {
    private static let shy = "\u{AD}"

    /// Longest first: «стопанството» contains «стопанство», and once its soft
    /// hyphens are in, the shorter pattern no longer matches inside it.
    private static let words: [(plain: String, broken: [String])] = [
        // «Дневник (PDF)»'s footer (#246): AX5 broke «Растителноза / щитните».
        ("Растителнозащитните", ["Рас", "ти", "тел", "но", "за", "щит", "ни", "те"]),
        ("стопанството", ["сто", "пан", "ство", "то"]),
        ("Стопанството", ["Сто", "пан", "ство", "то"]),
        ("стопанство", ["сто", "пан", "ство"]),
        ("Стопанство", ["Сто", "пан", "ство"]),
        // The composers' prompts (#225): in a field beside its send arrow,
        // AX5 broke «Напишет / е» and «съобщени / е».
        ("Напишете", ["На", "пи", "ше", "те"]),
        ("съобщение", ["съоб", "ще", "ние"]),
    ]

    /// `text` with soft hyphens in its long words; otherwise unchanged.
    static func display(_ text: String) -> String {
        words.reduce(text) { text, word in
            text.replacingOccurrences(of: word.plain, with: word.broken.joined(separator: shy))
        }
    }
}
