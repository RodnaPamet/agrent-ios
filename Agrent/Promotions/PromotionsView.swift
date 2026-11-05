import SwiftUI

/// «Промоции» (#528, owner 2026-11-02): the offers suppliers have published
/// for every farm, newest first, in «Меню» (not for a mechanisator, whose
/// app stays one screen). Each says who, what, until when, and lets someone
/// who may write ask the supplier for an offer (`PromotionLeadSheet`).
///
/// Nothing published is a real state, the first one it will be in: it says
/// so plainly rather than looking like a failed load (owner: "show it, with
/// an honest empty state").
struct PromotionsView: View {
    var body: some View {
        RoutedStack {
            PromotionsScreen()
        }
    }
}

private struct PromotionsScreen: View {
    @State private var store = PromotionsStore()
    @State private var people = CurrentUserStore.shared
    @State private var asking: PromotionsAPI.Promotion?
    @State private var page: InAppPage?
    @State private var notice: PromotionNotice?

    var body: some View {
        content
            .navigationTitle(PromotionsText.title)
            .appMenu()
            .task { await store.load() }
            .sheet(item: $asking) { promotion in
                PromotionLeadSheet(promotion: promotion) { outcome in
                    switch outcome {
                    case .sent:
                        store.markRequested(promotion.id)
                        notice = PromotionNotice(title: PromotionsText.sentTitle,
                                                 message: PromotionsText.sent(promotion.company))
                    case .alreadySent:
                        store.markRequested(promotion.id)
                        notice = PromotionNotice(title: PromotionsText.sentTitle,
                                                 message: PromotionsText.alreadySent(promotion.company))
                    case .noLongerRunning:
                        notice = PromotionNotice(title: PromotionsText.title, message: PromotionsText.ended)
                        Task { await store.load() }
                    }
                }
            }
            .sheet(item: $page) { InAppBrowser(url: $0.url).ignoresSafeArea() }
            .alert(notice?.title ?? "", isPresented: noticeShown, presenting: notice) { _ in
                Button("Добре", role: .cancel) { notice = nil }
            } message: { notice in
                Text(notice.message)
            }
    }

    private var noticeShown: Binding<Bool> {
        Binding { notice != nil } set: { if !$0 { notice = nil } }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await store.load() }
        case .loaded(let promotions, _) where promotions.isEmpty:
            EmptyState(PromotionsText.emptyTitle, icon: "tag", message: PromotionsText.emptyMessage)
                .refreshable { await PullToRefresh.bounded { await store.load() } }
        case .loaded(let promotions, _):
            List {
                Section {
                    ForEach(promotions) { promotion in
                        PromotionCard(promotion: promotion,
                                      mayAsk: people.user?.mayWrite ?? true,
                                      ask: { asking = promotion },
                                      openPage: { page = InAppPage(url: $0) })
                    }
                } footer: {
                    SectionFooter { Text(PromotionsText.note) }
                }
                .pageRow()
            }
            .listStyle(.plain)
            .pageBackground()
            .refreshable { await PullToRefresh.bounded { await store.load() } }
        }
    }
}

/// One offer: the supplier's picture, who, what, until when and of what
/// kind; then the ask and the supplier's own page.
private struct PromotionCard: View {
    let promotion: PromotionsAPI.Promotion
    /// Someone who may write: the server takes a request from no one else
    /// (`assertCanWrite`; the owner kept it so, 2026-11-02).
    let mayAsk: Bool
    let ask: () -> Void
    let openPage: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let path = promotion.mediaUrl {
                    PromotionImage(path: path)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(promotion.company)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                    Text(promotion.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body = promotion.body {
                        Text(body)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    MetaRow {
                        Text(promotion.category.label)
                        if let until = promotion.validTo {
                            MetaSeparator()
                            Text(PromotionsText.validUntil(until))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 16) {
                if promotion.hasRequested {
                    Label(PromotionsText.requested, systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                } else if mayAsk {
                    Button(PromotionsText.ask, action: ask)
                        .buttonStyle(.bordered)
                        .accessibilityHint(PromotionsText.askHint(promotion.company))
                        .accessibilityInputLabels(A11y.spokenNames(PromotionsText.ask, "Ask for offer"))
                }
                if let url = promotion.ctaUrl {
                    Button(PromotionsText.learnMore) { openPage(url) }
                        .buttonStyle(.borderless)
                        .accessibilityInputLabels(A11y.spokenNames(PromotionsText.learnMore, "Learn more"))
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// The supplier's picture, from app.agrent.bg's own route. Decorative: the
/// supplier and the title beside it already say what it is, as the web's
/// empty `alt` does.
private struct PromotionImage: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.Surface.card
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.Surface.edge, lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: path) {
            guard let data = try? await APIClient.shared.data(for: path) else { return }
            image = AccountAvatarAPI.image(from: data)
        }
    }
}

/// What the screen tells the person after the sheet closes.
private struct PromotionNotice: Equatable {
    let title: String
    let message: String
}

/// The screen's words, the web's where it has them (`ag.offers`).
enum PromotionsText {
    static let title = "Промоции"
    static let emptyTitle = "Още няма промоции"
    static let emptyMessage = "Доставчиците още не са публикували промоции. Новите ще се появяват тук."
    static let note = "Промоции и оферти от доставчици за земеделието, едни и същи за всички стопанства."
    static let ask = "Поискай оферта"
    static func askHint(_ company: String) -> String { "Изпраща запитване до \(company)" }
    static let requested = "Заявката е изпратена"
    static let learnMore = "Научете повече"
    static let sentTitle = "Заявката е изпратена"
    static func sent(_ company: String) -> String {
        "Заявката е изпратена до \(company). Ще я намерите в известията си."
    }
    static func alreadySent(_ company: String) -> String { "Вече попитахте \(company) за тази оферта." }
    static let ended = "Тази оферта не е активна в момента. Възможно е да е изтекла, оттеглена или още да не е започнала."

    /// «Валидна до 30 ноември», with the year when it is not this one.
    static func validUntil(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return "Валидна до \(sameYear ? BgDate.dayMonth(day) : BgDate.full(day))"
    }
}
