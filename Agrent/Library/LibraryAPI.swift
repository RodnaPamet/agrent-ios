import Foundation

/// «Вдъхновение» (#580, owner 2026-11-12): a library of openly available
/// books for different use cases, the same for every farm and every role,
/// mechanisators included. Contract: agri-saas #2980.
///
/// ── Only texts we may give away ──
///
/// A book qualifies when its original AND its translation are free to use in
/// the EU. The first, Sun Tzu's «Изкуството на войната», is Agrent's own
/// translation from the public-domain Chinese; Giles' 1910 English is
/// protected in the EU until the end of 2028. Texts never go into the code:
/// the superuser uploads a book and publishes it after the owner reads it.
///
/// ── Not a farm's data ──
///
/// `/api/library/…` is outside `/api/t/{slug}`, so it is the same for every
/// farm, and the server's MECHANISATOR confinement (which engages only on a
/// tenant path) leaves it open to them. Behind `library.enabled`, off by
/// default, until the server switches it on.
enum LibraryAPI {
    static let flag = "library.enabled"

    static let listPath = "/api/library/books"
    static func bookPath(_ slug: String) -> String { "\(listPath)/\(URLEscape.segment(slug))" }

    static func decodeList(_ data: Data) async throws -> [BookSummary] {
        try await APIClient.shared.decode(data, as: BookList.self).books
    }

    static func decodeBook(_ data: Data) async throws -> Book {
        try await APIClient.shared.decode(data, as: Book.self)
    }
}

/// A book on the shelf.
struct BookSummary: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let slug: String
    let title: String
    let author: String?
    let translator: String?
    let useCases: [String]
    let summary: String?
    let chapterCount: Int?
    /// Bumped by the server whenever the text changes.
    let version: Int?

    var id: String { slug }

    private enum CodingKeys: String, CodingKey { case slug, title, author, translator, useCases, summary, chapterCount, version }
    init(slug: String, title: String, author: String?, translator: String?, useCases: [String],
         summary: String?, chapterCount: Int?, version: Int?) {
        self.slug = slug
        self.title = title
        self.author = author
        self.translator = translator
        self.useCases = useCases
        self.summary = summary
        self.chapterCount = chapterCount
        self.version = version
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        translator = try? c.decodeIfPresent(String.self, forKey: .translator)
        useCases = (try? c.decodeIfPresent([String].self, forKey: .useCases)) ?? []
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        chapterCount = try? c.decodeIfPresent(Int.self, forKey: .chapterCount)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }
}

/// A whole book, kept for reading without signal.
struct Book: Decodable, Equatable, Sendable {
    let summary: BookSummary
    let sourceNote: String?
    let licenseNote: String?
    let chapters: [Chapter]

    struct Chapter: Decodable, Equatable, Hashable, Sendable, Identifiable {
        let number: Int
        let title: String
        /// The chapter's title in the original language, e.g. «始計第一».
        let originalTitle: String?
        let paragraphs: [String]
        var id: Int { number }
    }

    private enum CodingKeys: String, CodingKey { case sourceNote, licenseNote, chapters }
    init(summary: BookSummary, sourceNote: String?, licenseNote: String?, chapters: [Chapter]) {
        self.summary = summary
        self.sourceNote = sourceNote
        self.licenseNote = licenseNote
        self.chapters = chapters
    }
    init(from decoder: any Decoder) throws {
        summary = try BookSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceNote = try? c.decodeIfPresent(String.self, forKey: .sourceNote)
        licenseNote = try? c.decodeIfPresent(String.self, forKey: .licenseNote)
        chapters = ((try? c.decode([LibraryLossy<Chapter>].self, forKey: .chapters)) ?? []).compactMap(\.value)
            .sorted { $0.number < $1.number }
    }
}

private struct BookList: Decodable {
    let books: [BookSummary]
    private enum CodingKeys: String, CodingKey { case books }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = ((try? c.decode([LibraryLossy<BookSummary>].self, forKey: .books)) ?? []).compactMap(\.value)
    }
}

/// The shelves, in Bulgarian. The server validates the codes against a known
/// set (agri-saas #2980), so a new one is added here with it; until then it
/// lands under «Други».
enum BookUseCase {
    /// The server sends CODES in capitals (`STRATEGY`, agri-saas #3019),
    /// an enum the database enforces; read case-blind all the same.
    static func label(_ code: String) -> String {
        switch code.lowercased() {
        case "strategy": "Стратегия"
        case "management": "Управление"
        case "farming": "Земеделие"
        case "negotiation": "Преговори"
        case "leadership": "Лидерство"
        default: "Други"
        }
    }

    /// The books by shelf, shelves in the order their first book comes, a
    /// book with no code under «Други».
    static func shelves(_ books: [BookSummary]) -> [(label: String, books: [BookSummary])] {
        var order: [String] = []
        var byLabel: [String: [BookSummary]] = [:]
        for book in books {
            for label in Set((book.useCases.isEmpty ? [""] : book.useCases).map(Self.label)).sorted() {
                if byLabel[label] == nil { order.append(label) }
                byLabel[label, default: []].append(book)
            }
        }
        return order.map { ($0, byLabel[$0] ?? []) }
    }
}

/// One bad row costs that row, never the shelf or the book.
private struct LibraryLossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
