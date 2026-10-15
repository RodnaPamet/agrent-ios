import SwiftUI

/// «Ферми»: the farms that have published a page, pushed from Борса's
/// toolbar while `social.public-profile` is on (#323).
///
/// ── In Борса, and a farm opens as its web page (owner, 2026-10-15) ──
///
/// Борса is where farmers already look for each other. A tap opens the
/// farm's public page, `/f/{handle}`, in Safari's view inside the app. The
/// server has no JSON read of one farm's page, only the HTML, so a native
/// screen would have to leave out the description.
///
/// The web has no directory screen yet. The phone is first here (PARITY.md).
struct FarmDirectoryView: View {
    @State private var store = FarmDirectoryStore()
    @State private var page: WebPage?

    var body: some View {
        VStack(spacing: 0) {
            // Searched on SUBMIT, as Борса's board is: a round trip per
            // character on a field connection, for a name.
            SearchField(text: $store.query.text, prompt: "Търсене по име на ферма") {
                Task { await store.load() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            content
        }
        // The strip around the search field, as on Борса: the list below
        // paints the page, the field sits outside it.
        .background(Palette.Surface.page)
        .inlineTitle("Ферми")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { filterMenu }
        }
        .task { if store.state.value == nil { await store.load() } }
        .sheet(item: $page) { page in
            InAppBrowser(url: page.url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorState(message: message) { await store.load() }

        case .loaded(let hits, _) where hits.isEmpty:
            // A search that finds nothing isn't a claim that no farm is here.
            if store.query.isFiltered || !store.query.text.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyState(
                    "Няма съвпадения",
                    icon: "magnifyingglass",
                    message: "Никоя ферма не отговаря на търсенето."
                ) {
                    if store.query.isFiltered {
                        Button("Изчисти филтрите") { Task { await store.clearFilters() } }
                    }
                }
            } else {
                EmptyState(
                    "Още няма ферми",
                    icon: "house.and.flag",
                    message: "Никое стопанство не е публикувало своя страница."
                )
            }

        case .loaded(let hits, _):
            List {
                Section {
                    ForEach(hits) { hit in
                        Button { open(hit) } label: {
                            FarmDirectoryRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                        // A tap leaves Борса for a web page: said, because
                        // nothing in the row's words says it.
                        .accessibilityHint("Отваря страницата на фермата.")
                    }
                } footer: {
                    SectionFooter(Self.footer(count: hits.count))
                }
                .pageRow()
            }
            .refreshable { await PullToRefresh.bounded { await store.load() } }
            .pageBackground()
        }
    }

    /// The server stops at `FarmDirectoryAPI.limit` with no next page, so a
    /// full answer says how to reach the rest.
    nonisolated static func footer(count: Int) -> String {
        count >= FarmDirectoryAPI.limit
            ? "Показани са първите \(count). Стеснете търсенето по област или култура."
            : "Фермите, публикували своя страница в Agrent."
    }

    private func open(_ hit: FarmDirectoryHit) {
        guard let url = PublicProfileLink.url(handle: hit.handle), InAppBrowser.opens(url) else { return }
        page = WebPage(url: url)
    }

    // MARK: - Filters

    private var filterMenu: some View {
        Menu {
            // Submenus, not inline lists: 28 oblasts inline would push the
            // crops off the bottom of the menu.
            Picker("Област", selection: filter(\.oblast)) {
                Text("Всички").tag(String?.none)
                ForEach(FarmBrandLimits.oblasts(keeping: store.query.oblast), id: \.self) {
                    Text($0).tag(Optional($0))
                }
            }
            .pickerStyle(.menu)
            if !store.knownCrops.isEmpty {
                Picker("Култура", selection: filter(\.crop)) {
                    Text("Всички").tag(String?.none)
                    ForEach(store.knownCrops, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            if store.query.isFiltered {
                Divider()
                Button("Изчисти филтрите") { Task { await store.clearFilters() } }
            }
        } label: {
            Label(
                "Филтри",
                systemImage: store.query.isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        // A stable name and the state as a value, as Борса's filter has:
        // see `ExchangeView.filterMenu`.
        .accessibilityLabel("Филтри")
        .accessibilityValue(store.query.isFiltered ? "активни" : "")
        .accessibilityInputLabels(A11y.Spoken.filters)
    }

    /// A filter choice searches at once: there is no field to submit.
    private func filter(_ key: WritableKeyPath<FarmDirectoryQuery, String?>) -> Binding<String?> {
        Binding(
            get: { store.query[keyPath: key] },
            set: { value in
                store.query[keyPath: key] = value
                Task { await store.load() }
            }
        )
    }
}

/// The page a tap opened. A type of its own because `sheet(item:)` needs an
/// identity and `URL` has none.
private struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
