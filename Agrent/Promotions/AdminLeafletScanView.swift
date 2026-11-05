import PhotosUI
import SwiftUI

/// A supplier's leaflet, read (#529, agri-saas `leaflet-scan`): a photo, a
/// picture from Photos or a PDF from Files goes up; the server proposes the
/// offers it read; the owner opens each, checks it and saves a draft. The
/// read creates nothing, and what it could not read is said, not swallowed.
struct AdminLeafletScanView: View {
    let companies: [AdminPromotionsAPI.Company]
    /// A proposal, as the draft the editor opens on.
    let take: (AdminPromotionsAPI.Draft) -> Void

    @State private var scan: AdminPromotionsAPI.LeafletScan?
    @State private var reading = false
    @State private var refusal: String?
    @State private var photographing = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PageForm {
                if let scan {
                    proposals(scan)
                } else {
                    Section {
                        Button { photographing = true } label: { Label("Снимай листовката", systemImage: "camera") }
                            .accessibilityInputLabels(A11y.spokenNames("Снимай", "Camera"))
                        Button { choosingPhoto = true } label: { Label("От снимките", systemImage: "photo.on.rectangle") }
                            .accessibilityInputLabels(A11y.spokenNames("От снимките", "Photos"))
                        Button { importing = true } label: { Label("От файловете (PDF)", systemImage: "folder") }
                            .accessibilityInputLabels(A11y.spokenNames("От файловете", "Files"))
                    } footer: {
                        SectionFooter {
                            if reading {
                                Text("Листовката се прочита…")
                            } else if let refusal {
                                Text(refusal).foregroundStyle(Palette.error)
                            } else {
                                Text("Листовката се прочита и се предлагат промоциите от нея. Нищо не се записва, докато не проверите всяка.")
                            }
                        }
                    }
                    .disabled(reading)
                }
            }
            .inlineTitle(AdminPromotionsText.fromLeaflet)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Затвори") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.close)
                }
            }
            .fullScreenCover(isPresented: $photographing) {
                CameraPicker { image in
                    photographing = false
                    if let jpeg = Self.jpeg(image) { read(jpeg, fileName: "leaflet.jpg", mimeType: "image/jpeg") }
                } onCancel: {
                    photographing = false
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let jpeg = Self.jpeg(image) {
                        read(jpeg, fileName: "leaflet.jpg", mimeType: "image/jpeg")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
                guard case .success(let url) = result else { return }
                switch DocumentUploads.file(at: url) {
                case .success(let file): read(file.data, fileName: file.fileName, mimeType: file.mimeType)
                case .failure(let refused): refusal = refused.message
                }
            }
        }
    }

    @ViewBuilder
    private func proposals(_ scan: AdminPromotionsAPI.LeafletScan) -> some View {
        Section {
            if scan.offers.isEmpty {
                Text("В листовката не беше прочетена промоция.")
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(scan.offers) { offer in
                Button {
                    take(Self.draft(offer, company: scan.companyName))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(offer.productName).font(.subheadline.weight(.semibold))
                        ForEach([offer.priceText, offer.validityText, offer.note].compactMap { $0?.recorded }, id: \.self) {
                            Text($0).font(.footnote).foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Отваря я като чернова за проверка")
            }
        } header: {
            SectionHeader(scan.companyName.map { "Предложения от \($0)" } ?? "Предложения")
        } footer: {
            SectionFooter {
                if scan.unreadableOfferCount > 0 {
                    Text("\(Plural.bg(scan.unreadableOfferCount, "оферта не можа", "оферти не можаха")) да бъдат прочетени. Проверете листовката и ги добавете ръчно.")
                        .foregroundStyle(Palette.warning)
                } else {
                    Text("Докоснете предложение, за да го проверите и запишете като чернова.")
                }
            }
        }
    }

    private func read(_ file: Data, fileName: String, mimeType: String) {
        reading = true
        refusal = nil
        Task {
            defer { reading = false }
            do {
                scan = try await AdminPromotionsAPI.scanLeaflet(file, fileName: fileName, mimeType: mimeType)
            } catch {
                refusal = UserMessage.text(for: error)
            }
        }
    }

    static func jpeg(_ image: UIImage) -> Data? {
        ScanPDF.compressed(image).jpegData(compressionQuality: ScanPDF.quality)
    }

    /// A proposal as a draft: its product the title, the price exactly as
    /// printed and the rest as text, its supplier as read. Nothing guessed:
    /// the validity stays text for the owner to set as days.
    static func draft(_ offer: AdminPromotionsAPI.LeafletScan.Offer, company: String?) -> AdminPromotionsAPI.Draft {
        var draft = AdminPromotionsAPI.Draft()
        draft.title = offer.productName
        draft.body = [offer.priceText, offer.validityText, offer.note].compactMap { $0?.recorded }.joined(separator: "\n")
        draft.companyName = company?.recorded ?? ""
        return draft
    }
}
