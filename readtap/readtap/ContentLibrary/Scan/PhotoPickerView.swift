import SwiftUI
import PhotosUI

/// Errors surfaced by the photo picker coordinator.
enum PhotoPickerError: Error, LocalizedError {
    case cancelled
    case loadFailed(Error)
    case noImages

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Photo selection cancelled."
        case .loadFailed(let error):
            return "Couldn't load the selected photos: \(error.localizedDescription)"
        case .noImages:
            return "No images were selected."
        }
    }
}

/// SwiftUI wrapper around `PHPickerViewController` for multi-image selection.
///
/// `PHPickerViewController` runs out-of-process so it does NOT require the
/// `NSPhotoLibraryUsageDescription` key in Info.plist.
struct PhotoPickerView: UIViewControllerRepresentable {
    typealias CompletionHandler = (Result<[UIImage], PhotoPickerError>) -> Void

    /// `0` means unlimited selection (PHPicker convention).
    var selectionLimit: Int = 0
    let onCompletion: CompletionHandler

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // No-op: PHPicker owns its own state.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onCompletion: CompletionHandler
        private var didReport = false

        init(onCompletion: @escaping CompletionHandler) {
            self.onCompletion = onCompletion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                report(.failure(.cancelled))
                return
            }

            // Load each provider in parallel while preserving the user's selection order.
            // We use an indexed dictionary because `loadObject` completes on arbitrary
            // threads and order is not guaranteed.
            Task {
                let loaded = await Self.loadImagesPreservingOrder(from: results)
                await MainActor.run {
                    switch loaded {
                    case .success(let images) where images.isEmpty:
                        self.report(.failure(.noImages))
                    case .success(let images):
                        self.report(.success(images))
                    case .failure(let error):
                        self.report(.failure(.loadFailed(error)))
                    }
                }
            }
        }

        private func report(_ result: Result<[UIImage], PhotoPickerError>) {
            guard !didReport else { return }
            didReport = true
            onCompletion(result)
        }

        /// Loads every provider's `UIImage` representation in parallel, then reorders
        /// the results to match the original selection order. Returns `.failure` if
        /// any single provider fails.
        private static func loadImagesPreservingOrder(
            from results: [PHPickerResult]
        ) async -> Result<[UIImage], Error> {
            await withTaskGroup(of: (Int, Result<UIImage?, Error>).self) { group in
                for (index, result) in results.enumerated() {
                    let provider = result.itemProvider
                    group.addTask {
                        guard provider.canLoadObject(ofClass: UIImage.self) else {
                            return (index, .success(nil))
                        }
                        return await withCheckedContinuation { continuation in
                            provider.loadObject(ofClass: UIImage.self) { object, error in
                                if let error = error {
                                    continuation.resume(returning: (index, .failure(error)))
                                } else {
                                    continuation.resume(returning: (index, .success(object as? UIImage)))
                                }
                            }
                        }
                    }
                }

                var indexed: [(Int, UIImage)] = []
                indexed.reserveCapacity(results.count)

                for await (index, outcome) in group {
                    switch outcome {
                    case .failure(let error):
                        group.cancelAll()
                        return .failure(error)
                    case .success(let image):
                        if let image = image {
                            indexed.append((index, image))
                        }
                    }
                }

                indexed.sort { $0.0 < $1.0 }
                return .success(indexed.map { $0.1 })
            }
        }
    }
}
