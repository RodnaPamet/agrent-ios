import SwiftUI

/// «Известия» (#471, owner 2026-10-30): the server's notifications for the
/// signed-in person, newest first. In the menu with the unread count, as
/// Борса's row has, and choosable for the bar. A notification opens what it
/// is about where the app can show it (`PushLink`), and is marked read.
struct NotificationsView: View {
    var body: some View {
        RoutedStack {
            NotificationsScreen()
        }
    }
}

private struct NotificationsScreen: View {
    @State private var store = NotificationsStore.shared
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        content
            .navigationTitle("Известия")
            .appMenu()
            .task { await store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.refresh() }
        case .loaded(let items, _) where items.isEmpty:
            EmptyState("Няма известия", icon: "bell", message: "Тук ще виждате известията за стопанството.")
        case .loaded(let items, _):
            List {
                Group {
                    ForEach(items) { item in
                        Button { Task { await open(item) } } label: {
                            NotificationRow(item: item, opens: item.link(inFarm: store.farm) != nil)
                        }
                            .buttonStyle(.plain)
                    }
                    // The server sends the newest 50 and does not say when
                    // there were more, so the page says what it is showing.
                    if items.count >= NotificationsAPI.cap {
                        Text("Показани са последните \(NotificationsAPI.cap) известия.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .listRowSeparator(.hidden)
                    }
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.refresh() } }
        }
    }

    /// Read, then where it leads, if the app can show it there.
    private func open(_ item: AppNotification) async {
        await store.markRead(item)
        if let link = item.link(inFarm: store.farm) {
            pushRoute(AppRoute(link))
        }
    }
}

/// One notification: unread marked by a dot AND a word for VoiceOver, its
/// title, its text, and when.
private struct NotificationRow: View {
    let item: AppNotification
    /// Whether a tap leads somewhere: the chevron says so.
    let opens: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(item.read ? Color.clear : Palette.accent)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline.weight(item.read ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = item.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let when {
                    Text(when)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([item.read ? nil : "Ново", item.title, item.message, when]))
        .accessibilityAddTraits(.isButton)
    }

    private var when: String? { item.createdAt.map { BgDate.messageTime($0) } }
}
