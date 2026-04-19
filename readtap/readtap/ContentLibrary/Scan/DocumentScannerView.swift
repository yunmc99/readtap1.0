import SwiftUI
import VisionKit

/// Errors surfaced by the document scanner coordinator.
enum DocumentScannerError: Error, LocalizedError {
    case cancelled
    case failed(Error)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Scan cancelled."
        case .failed(let error):
            return "Scan failed: \(error.localizedDescription)"
        case .notAvailable:
            return "Document scanning is not available on this device."
        }
    }
}

/// SwiftUI wrapper around VisionKit's `VNDocumentCameraViewController`.
///
/// VisionKit's scanner handles live edge detection, perspective correction,
/// color/grayscale/B&W filtering, and the keep/retake UI for multi-page
/// captures — we just hand the final `[UIImage]` pages back to the caller.
struct DocumentScannerView: UIViewControllerRepresentable {
    typealias CompletionHandler = (Result<[UIImage], DocumentScannerError>) -> Void

    let onCompletion: CompletionHandler

    /// `true` when the current device actually supports document scanning.
    /// Always `false` on simulators without a camera.
    static var isAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        // No-op: VisionKit owns the camera state.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onCompletion: CompletionHandler
        private var didReport = false

        init(onCompletion: @escaping CompletionHandler) {
            self.onCompletion = onCompletion
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            report(.success(images))
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            report(.failure(.cancelled))
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            report(.failure(.failed(error)))
        }

        private func report(_ result: Result<[UIImage], DocumentScannerError>) {
            guard !didReport else { return }
            didReport = true
            onCompletion(result)
        }
    }
}
