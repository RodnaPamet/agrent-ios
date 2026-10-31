import SwiftUI

/// A listing named only by id, from a notification's link (#475): someone
/// is interested in, or asking about, the farm's listing. Read live, as
/// Борса's messaging is, then shown as a row's tap would show it.
struct ListingLinkView: View {
    let id: String

    @State private var state: LoadState<ExchangeListing> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Зареждане на обявата")
            case .failed(let message):
                ErrorState(message: message) { await load() }
            case .loaded(let listing, _):
                ListingDetailView(listing: listing)
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            let listing = try await APIClient.shared.get(ExchangeAPI.listingPath(id), as: ExchangeListing.self)
            state = .loaded(listing, .fresh)
        } catch {
            state = .failed(UserMessage.text(for: error))
        }
    }
}
