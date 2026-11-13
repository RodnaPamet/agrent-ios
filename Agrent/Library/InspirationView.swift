import SwiftUI

/// «Вдъхновение» (#580): the library's shelves, each book by its use case.
/// A menu row for every role, mechanisators included (owner, 2026-11-12),
/// in a stack of its own.
///
/// ── Kept for reading without signal ──
///
/// The books are the same for everyone and name nobody, so the list and
/// every book go through `ResponseCache` (cache first, revalidated by ETag)
/// and are fetched ahead by `OfflinePrefetch`. A book opened once, or warmed
/// once, reads in a field with no signal.
struct InspirationView: View {
    @State private var state: LoadState<[BookSummary]> = .loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Вдъхновение")
                .navigationDestination(for: BookSummary.self) { BookView(summary: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { if state.value == nil { await load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let books, _) where books.isEmpty:
            ContentUnavailableView("Още няма книги", systemImage: "books.vertical",
                                   description: Text("Книгите в библиотеката ще се появят тук."))
        case .loaded(let books, _):
            List {
                ForEach(BookUseCase.shelves(books), id: \.label) { shelf in
                    Section {
                        ForEach(shelf.books) { book in
                            NavigationLink(value: book) { row(book) }
                        }
                    } header: {
                        SectionHeader(shelf.label)
                    }
                    .pageRow()
                }
            }
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await load(showCachedFirst: false) } }
        }
    }

    private func row(_ book: BookSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.title).font(.headline)
            if let author = book.author {
                Text(author).font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            if let summary = book.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func load(showCachedFirst: Bool = true) async {
        await CachedResource.loadShowingCacheFirst(LibraryAPI.listPath, showCachedFirst: showCachedFirst) { data in
            try await LibraryAPI.decodeList(data)
        } publish: { state = $0 }
    }
}

/// One book: what it is, where its text comes from, and its chapters.
struct BookView: View {
    let summary: BookSummary
    @State private var state: LoadState<Book> = .loading

    var body: some View {
        content
            .inlineTitle(summary.title)
            .navigationDestination(for: ChapterRoute.self) { route in
                if let book = state.value {
                    ChapterView(book: book, number: route.number)
                }
            }
            .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let book, _):
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.summary.title).font(.title2.weight(.semibold))
                        if let author = book.summary.author {
                            Text(author).font(.subheadline).foregroundStyle(Palette.secondaryText)
                        }
                        if let summary = book.summary.summary {
                            Text(summary).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .pageRow()
                Section {
                    ForEach(book.chapters) { chapter in
                        NavigationLink(value: ChapterRoute(number: chapter.number)) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(chapter.number)")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Palette.accent)
                                    .frame(minWidth: 24, alignment: .trailing)
                                Text(chapter.title)
                            }
                        }
                        .accessibilityLabel("Глава \(chapter.number): \(chapter.title)")
                    }
                } header: {
                    SectionHeader("Глави")
                }
                .pageRow()
                Section {
                    Text(BookWords.about(book))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    SectionHeader("За книгата")
                }
                .pageRow()
            }
            .pageBackground()
        }
    }

    private func load() async {
        await CachedResource.loadShowingCacheFirst(LibraryAPI.bookPath(summary.slug)) { data in
            try await LibraryAPI.decodeBook(data)
        } publish: { state = $0 }
    }
}

/// A chapter, pushed by value onto the library's own stack.
struct ChapterRoute: Hashable {
    let number: Int
}

/// One chapter to read: its title, the original title, the text in the
/// reader's own text size, and the way on to the next.
struct ChapterView: View {
    let book: Book
    @State var number: Int

    private var chapter: Book.Chapter? { book.chapters.first { $0.number == number } }
    private var next: Book.Chapter? { book.chapters.first { $0.number > number } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let chapter {
                        VStack(alignment: .leading, spacing: 4) {
                            // The house heading: gold, and a heading to VoiceOver.
                            SectionTitle("Глава \(chapter.number). \(chapter.title)", font: .title2.weight(.semibold))
                            if let original = chapter.originalTitle {
                                Text(original).font(.subheadline).foregroundStyle(Palette.secondaryText)
                            }
                        }
                        .id("top")
                        ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.body)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let next {
                            Button {
                                number = next.number
                                proxy.scrollTo("top", anchor: .top)
                            } label: {
                                Label("Следваща глава: \(next.title)", systemImage: "arrow.right")
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 8)
                            .accessibilityInputLabels(A11y.spokenNames("Следваща глава", "Next chapter"))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .pageBackground()
        .inlineTitle(book.summary.title)
    }
}

/// What the screens say about a book, pure so tests pin it.
enum BookWords {
    /// «За книгата»: the translator, where the text comes from, and why it
    /// may be given away.
    static func about(_ book: Book) -> String {
        [book.summary.translator.map { "Превод: \($0)." }, book.sourceNote, book.licenseNote]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
