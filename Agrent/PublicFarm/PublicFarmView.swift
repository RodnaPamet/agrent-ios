import SwiftUI

/// A farm's public page, on the phone (#536, owner 2026-11-06: "build it"):
/// its logo, name, tagline, oblast, crops, «За нас» and photos, as
/// `/f/{handle}` shows them on the web, and the link to share.
///
/// Opened from Борса's farm search and a listing's farm link, and by a
/// `/f/{handle}` link once the app claims it again (agri-saas: only after
/// this screen has shipped, on the owner's word).
struct PublicFarmView: View {
    let handle: String

    @State private var state: LoadState<PublicFarmAPI.Farm> = .loading
    @State private var notPublic = false
    @State private var flags = FeatureFlags.shared
    @State private var opener = DirectConversationOpener()
    /// The conversation goes onto the stack once the server answers with its
    /// id — but only if this page is still on screen then.
    @Environment(\.pushRoute) private var pushRoute
    @State private var isShown = false

    var body: some View {
        content
            .inlineTitle(PublicFarmText.title)
            .pageBackground()
            .task { if state.value == nil { await load() } }
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .refreshable { await PullToRefresh.bounded { await load() } }
            .toolbar {
                if let url = PublicProfileLink.url(handle: handle) {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Label(PublicFarmText.share, systemImage: "square.and.arrow.up")
                        }
                        .accessibilityInputLabels(A11y.spokenNames(PublicFarmText.share, "Share"))
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where notPublic:
            EmptyState(PublicFarmText.notPublicTitle, icon: "lock", message: PublicFarmText.notPublicMessage)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let farm, _):
            List {
                Group {
                    header(farm)
                    if flags.isOn(DirectMessagesAPI.flag) {
                        writeSection(farm)
                    }
                    if !farm.crops.isEmpty {
                        Section {
                            CropChips(crops: farm.crops)
                        } header: {
                            SectionHeader(PublicFarmText.crops)
                        }
                    }
                    if let about = farm.about {
                        Section {
                            Text(about)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } header: {
                            SectionHeader(PublicFarmText.about)
                        }
                    }
                    if !farm.photoUrls.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(Array(farm.photoUrls.enumerated()), id: \.offset) { index, path in
                                        PublicFarmImage(path: path, size: 200)
                                            .accessibilityLabel(PublicFarmText.photo(index + 1, of: farm.displayName))
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        } header: {
                            SectionHeader(PublicFarmText.photos)
                        }
                    }
                    Section {
                        Text(PublicProfileLink.displayAddress(handle: farm.handle))
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .textSelection(.enabled)
                    } footer: {
                        SectionFooter { Text(PublicFarmText.addressNote) }
                    }
                }
                .pageRow()
            }
            .listStyle(.insetGrouped)
            .pageBackground()
        }
    }

    private func header(_ farm: PublicFarmAPI.Farm) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                if let logo = farm.logoUrl {
                    PublicFarmImage(path: logo, size: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(farm.displayName)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let tagline = farm.tagline {
                        Text(tagline)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let oblast = farm.oblast {
                        Label(PublicFarmText.oblast(oblast), systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    /// «Пиши» (#593, owner 2026-11-13): a personal message to this farm. The
    /// server resolves the handle to the farm's active owner.
    ///
    /// ── NOT FIRED ──
    ///
    /// The tap opens a conversation request the owner sees at once. Built,
    /// wired, and never pressed against production.
    private func writeSection(_ farm: PublicFarmAPI.Farm) -> some View {
        Section {
            Button {
                Task {
                    if let id = await opener.open(handle: farm.handle), isShown {
                        pushRoute(.directConversation(id: id, title: farm.displayName))
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Label("Пиши", systemImage: "bubble.left")
                    if opener.opening {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(opener.opening)
            .accessibilityLabel("Пиши на \(farm.displayName)")
            .accessibilityInputLabels(A11y.spokenNames("Пиши", "Съобщение", "Message"))
            if let failure = opener.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        notPublic = false
        await CachedResource.loadShowingCacheFirst(PublicFarmAPI.path(handle)) { data in
            try await PublicFarmAPI.decode(from: data)
        } publish: { state in
            self.state = state
        }
        if case .failed = state {
            // Asked once more, plainly, to tell "not public" from "no signal".
            do {
                _ = try await PublicFarmAPI.decode(from: APIClient.shared.data(for: PublicFarmAPI.path(handle)))
            } catch {
                notPublic = PublicFarmAPI.isNotPublic(error)
            }
        }
    }
}

/// A farm's crops as the chips the web draws.
private struct CropChips: View {
    let crops: [String]

    var body: some View {
        AdaptiveRow(spacing: 8) {
            ForEach(crops, id: \.self) { crop in
                CategoryChip(text: CommodityName.freeText(crop) ?? crop,
                             foreground: Palette.accent, background: Palette.accent.opacity(0.12))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A picture the farm published, from the server's public media route.
private struct PublicFarmImage: View {
    /// Root-relative, checked by the decoder (`PublicFarmAPI.isOurMedia`).
    let path: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.Surface.card
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 12 : 10))
        .overlay { RoundedRectangle(cornerRadius: size > 100 ? 12 : 10).strokeBorder(Palette.Surface.edge, lineWidth: 1) }
        .task(id: path) {
            guard let data = try? await APIClient.shared.data(for: path) else { return }
            image = AccountAvatarAPI.image(from: data)
        }
    }
}

enum PublicFarmText {
    static let title = "Стопанство"
    static let share = "Сподели"
    static let crops = "Култури"
    static let about = "За нас"
    static let photos = "Снимки"
    static let addressNote = "Публичният адрес на стопанството. Отваря тази страница и в браузър."
    static let notPublicTitle = "Страницата не е публична"
    static let notPublicMessage = "Това стопанство няма публична страница или я е оттеглило."
    static func oblast(_ name: String) -> String { "Област \(name)" }
    static func photo(_ n: Int, of farm: String) -> String { "Снимка \(n) от \(farm)" }
}
