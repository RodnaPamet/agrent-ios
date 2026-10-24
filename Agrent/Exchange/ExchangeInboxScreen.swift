import SwiftUI

/// «Съобщения», pushed from Борса's bar (owner, 2026-10-24): where the
/// «Ферми» button was, now that the directory lives in the board's search.
/// It used to be Борса's fourth section in the row under the title.
///
/// Its own store, so the inbox polls only while this screen is on screen,
/// as it did as a section. «Към обявите» on an empty inbox goes back to the
/// board, which is where a conversation starts.
struct ExchangeInboxScreen: View {
    @State private var store = ExchangeInboxStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExchangeInboxView(store: store, showListings: { dismiss() })
            .background(Palette.Surface.page)
            .inlineTitle("Съобщения")
    }
}
