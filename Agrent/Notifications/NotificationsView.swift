import SwiftUI

/// «Известия» (#471, owner 2026-10-30): the server's notifications for the
/// signed-in person, newest first. In the menu with the unread count, as
/// Борса's row has, and choosable for the bar. A notification opens what it
/// is about where the app can show it (`PushLink`), or a page outside the
/// app in Safari's view (#488), and is marked read.
struct NotificationsView: View {
    var body: some View {
        RoutedStack {
            NotificationsScreen()
        }
    }
}

private struct NotificationsScreen: View {
    @State private var store = NotificationsStore.shared
    /// The page outside the app a notification opened, while it is open.
    @State private var webPage: InAppPage?
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        content
            .navigationTitle("Известия")
            .appMenu()
            .task { await store.refresh() }
            .sheet(item: $webPage) { InAppBrowser(url: $0.url).ignoresSafeArea() }
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
                            NotificationRow(item: item, leads: NotificationRow.Lead(item, inFarm: store.farm))
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

    /// Read, then where it leads: a screen of the app, or a page outside it.
    private func open(_ item: AppNotification) async {
        UsageEvents.shared.record(.notificationOpened)
        await store.markRead(item)
        if let link = item.link(inFarm: store.farm) {
            pushRoute(AppRoute(link))
        } else if let url = item.webPage(inFarm: store.farm) {
            webPage = InAppPage(url: url)
        }
    }
}

/// One notification: unread marked by a dot AND a word for VoiceOver, its
/// title, its text, and when.
private struct NotificationRow: View {
    let item: AppNotification
    /// Where a tap leads, if anywhere: a chevron for a screen of the app, the
    /// box-and-arrow Safari links use for a page outside it.
    let leads: Lead?

    enum Lead: Equatable {
        case screen, web

        init?(_ item: AppNotification, inFarm farm: String?) {
            if item.link(inFarm: farm) != nil {
                self = .screen
            } else if item.webPage(inFarm: farm) != nil {
                self = .web
            } else {
                return nil
            }
        }
    }

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
            if let leads {
                Image(systemName: leads == .web ? "arrow.up.right.square" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([item.read ? nil : "Ново", item.title, item.message, when]))
        .accessibilityHint(leads == .web ? "Отваря страница извън приложението." : "")
        .accessibilityAddTraits(.isButton)
    }

    private var when: String? { item.createdAt.map { BgDate.messageTime($0) } }
}
