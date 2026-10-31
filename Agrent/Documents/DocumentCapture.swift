import QuickLook
import SwiftUI
import UIKit
import VisionKit

/// The document scanner (owner, 2026-10-30: «if possible to even scan them»):
/// VisionKit's camera finds the page's edges, straightens and cleans it, and
/// takes several pages in a row. Apple's own screen, so VoiceOver and Voice
/// Control work in it as Apple made them.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    /// False on a simulator and on a device without the camera it needs:
    /// then the camera button takes a plain photo instead.
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onCancel()
        }
    }
}

/// A scan's pages as ONE PDF (owner: a three-page contract is one document,
/// not three photos), made on the phone.
///
/// ── Small enough to send from a field ──
///
/// A scanned page is a full-resolution camera image. Each is scaled so its
/// longer side is at most `maxSide` points and drawn as a JPEG, which the
/// PDF keeps as JPEG: a page is a few hundred kilobytes rather than several
/// megabytes, and the farm's 2 GB lasts. A4 text stays sharp at that size.
enum ScanPDF {
    static let maxSide: CGFloat = 2000
    static let quality: CGFloat = 0.7

    static func make(_ pages: [UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        return renderer.pdfData { context in
            for page in pages {
                let image = compressed(page)
                let bounds = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }

    static func compressed(_ image: UIImage) -> UIImage {
        let longer = max(image.size.width, image.size.height)
        let scale = longer > maxSide ? maxSide / longer : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: quality), let back = UIImage(data: jpeg) else {
            return resized
        }
        return back
    }
}

/// A plain photo from the camera, where there is no scanner.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto, onCancel: onCancel) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPhoto: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPhoto = onPhoto
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPhoto(image) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// A document's preview: Quick Look, with its own share button (owner,
/// 2026-10-30: Files, Mail, print). The bytes are written to a temporary
/// file only for as long as the preview is open (`PreviewFile`).
struct DocumentPreview: UIViewControllerRepresentable {
    let file: URL
    let title: String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Затвори", style: .done, target: context.coordinator, action: #selector(Coordinator.close))
        preview.navigationItem.leftBarButtonItem?.accessibilityUserInputLabels = A11y.Spoken.close
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(file: file, title: title, onClose: onClose) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: Item
        let onClose: () -> Void

        init(file: URL, title: String, onClose: @escaping () -> Void) {
            item = Item(url: file, title: title)
            self.onClose = onClose
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }

        @objc func close() { onClose() }
    }

    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}

/// The bytes of one preview, on disk only while it is open: written to a
/// directory of their own under the temporary directory and removed with
/// it when the preview closes. A document can name a third party, so it
/// does not outlive the look at it.
struct PreviewFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    let title: String

    static func write(_ data: Data, title: String, fileName: String?, contentType: String?) throws -> PreviewFile {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("documents-preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.safeName(title: title, fileName: fileName, contentType: contentType))
        try data.write(to: url, options: [.completeFileProtection])
        return PreviewFile(url: url, title: title)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Quick Look picks its viewer by the extension, so the file gets one.
    /// The server's own name first; otherwise the title and an extension
    /// from the type. Never a path: only the last component is kept.
    static func safeName(title: String, fileName: String?, contentType: String?) -> String {
        if let fileName, !fileName.isEmpty, fileName.contains(".") {
            return (fileName as NSString).lastPathComponent
        }
        let ext: String
        switch DocumentKind(contentType: contentType) {
        case .pdf: ext = "pdf"
        case .image: ext = (contentType ?? "").contains("png") ? "png" : "jpg"
        case .word: ext = "docx"
        case .sheet: ext = (contentType ?? "").contains("csv") ? "csv" : "xlsx"
        case .text: ext = "txt"
        case .other: ext = "bin"
        }
        let base = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "document" : base).\(ext)"
    }
}
