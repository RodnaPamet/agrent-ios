import PhotosUI
import SwiftUI

/// The picture controls under the account card on Профил (#333): change it
/// from the photo library, or remove it.
///
/// As on the web, a pick uploads at once and «Премахване» asks nothing.
/// Each is undone by the other, and the photo itself stays in the library.
///
/// ── Rows in the card's section, not a section of their own ──
///
/// The picture and the controls that change it read as one group, and the
/// card above shows the result the moment it lands.
///
/// ── The photo library without a permission prompt ──
///
/// `PhotosPicker` runs outside the app and hands over only the photo the
/// person chose, so the app asks for no library access at all.
struct AccountPictureRows: View {
    let user: CurrentUser
    var me: CurrentUserStore = .shared
    var avatars: AccountAvatarStore = .shared

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picked: PhotosPickerItem?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        // Read here, outside the label closure: `PhotosPicker` takes that
        // closure as `@Sendable`, so it may not touch this view's state.
        let title = hasPicture ? AccountPicture.changeTitle : AccountPicture.uploadTitle
        // No icons at the accessibility sizes: beside the glyph at AX5,
        // «Премахване» broke «Премахва / не».
        let iconless = typeSize.isAccessibilitySize
        // `.current`: the library's own bytes, HEIC included, because the
        // conversion below reads them anyway. `.compatible` would have the
        // system transcode to JPEG first, and then this app would do it again.
        PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current) {
            if iconless { Text(title) } else { Label(title, systemImage: "photo") }
        }
        .disabled(working)
        .accessibilityInputLabels(hasPicture
            ? A11y.spokenNames(AccountPicture.changeTitle, "Change photo")
            : A11y.spokenNames(AccountPicture.uploadTitle, "Upload photo"))
        .onChange(of: picked) { _, item in
            guard let item else { return }
            // Cleared at once, so the same photo can be chosen again after a
            // failure, as the web clears its file input.
            picked = nil
            Task { await send(item) }
        }
        // Said, not only drawn: VoiceOver's focus stays on the picker.
        .onChange(of: failure) { _, now in
            guard let now else { return }
            AccessibilityNotification.Announcement(now).post()
        }

        if hasPicture {
            Button {
                Task { await remove() }
            } label: {
                if iconless {
                    Text(AccountPicture.removeTitle)
                } else {
                    Label(AccountPicture.removeTitle, systemImage: "xmark.circle")
                }
            }
            .disabled(working)
            .accessibilityInputLabels(A11y.spokenNames(AccountPicture.removeTitle, "Remove photo"))
        }

        if working {
            HStack(spacing: 10) {
                ProgressView()
                Text(AccountPicture.workingTitle)
            }
            .foregroundStyle(Palette.secondaryText)
            .accessibilityElement(children: .combine)
        }

        if let failure {
            Text(failure)
                .foregroundStyle(Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whatever `/me` names, an OAuth provider's photo included: the web
    /// offers «Смяна» and «Премахване» for that too.
    private var hasPicture: Bool { user.avatarUrl != nil }

    private func send(_ item: PhotosPickerItem) async {
        guard !working else { return }
        working = true
        failure = nil
        defer { working = false }
        // Captured before the first await. An upload that finishes after
        // Изход must not put this account's face into the shared store the
        // next person's Админ reads.
        let epoch = SessionEpoch.current
        let userID = user.id
        do {
            let original: Data
            do {
                guard let loaded = try await item.loadTransferable(type: Data.self) else {
                    throw AccountPicture.Failure.notLoaded
                }
                original = loaded
            } catch {
                throw AccountPicture.Failure.notLoaded
            }
            let jpeg = try await AccountPicture.jpeg(from: original)
            let avatarURL = try await AccountPicture.upload(jpeg)
            guard SessionEpoch.isCurrent(epoch) else { return }
            me.adoptAvatarURL(avatarURL)
            if let image = AccountAvatarAPI.image(from: jpeg) {
                avatars.adopt(userID: userID, avatarURL: avatarURL, image: image)
            }
            AccessibilityNotification.Announcement(AccountPicture.changed).post()
        } catch {
            guard SessionEpoch.isCurrent(epoch) else { return }
            failure = AccountPicture.message(for: error)
        }
    }

    private func remove() async {
        guard !working else { return }
        working = true
        failure = nil
        defer { working = false }
        let epoch = SessionEpoch.current
        do {
            try await AccountPicture.remove()
            guard SessionEpoch.isCurrent(epoch) else { return }
            // `/me` now says null, and the card's task turns that into
            // initials with no request (`AccountAvatarStore.load`).
            me.adoptAvatarURL(nil)
            AccessibilityNotification.Announcement(AccountPicture.removed).post()
        } catch {
            guard SessionEpoch.isCurrent(epoch) else { return }
            failure = AccountPicture.message(for: error)
        }
    }
}
