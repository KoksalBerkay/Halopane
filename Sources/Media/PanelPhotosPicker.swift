import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The iPhone photo picker for opening a photo or video in a screen.
struct PanelPhotosPicker: UIViewControllerRepresentable {
    let picked: (NSItemProvider?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(picked: picked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let picked: (NSItemProvider?) -> Void
        init(picked: @escaping (NSItemProvider?) -> Void) {
            self.picked = picked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picked(results.first?.itemProvider)
        }
    }

    static func open(_ provider: NSItemProvider) async throws -> LocalPanelFile {
        let suggestedName = provider.suggestedName
        let advertised = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        // Some Live Photos advertise a motion resource as well as a still.
        let still = advertised.contains { $0.conforms(to: .image) || $0.conforms(to: .livePhoto) }
        let media: UTType = still ? .image : .movie
        var types = advertised.filter { $0.conforms(to: media) }
        if still {
            types = types.filter { $0.conforms(to: .rawImage) } + types.filter { !$0.conforms(to: .rawImage) }
            let originals = types.filter { $0.conforms(to: .heic) || $0.conforms(to: .heif) }
            types = originals + types
            types.append(.jpeg)
        } else {
            types = types.filter { $0.conforms(to: .quickTimeMovie) } + types
        }
        types.append(media)
        var tried = Set<String>()
        var lastError: Error = LocalPanelFile.Issue.unsupported
        var rawError: Error?
        for type in types where tried.insert(type.identifier).inserted {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        // Decode/copy before returning control to the picker.
                        continuation.resume(
                            with: Result {
                                guard let url else {
                                    throw error ?? LocalPanelFile.Issue.inaccessible
                                }
                                return try LocalPanelFile.stagePhotoTransfer(
                                    url, type: type, suggestedName: suggestedName)
                            })
                    }
                }
            } catch {
                if type.conforms(to: .rawImage) {
                    rawError = error
                }
                lastError = error
            }
        }
        if rawError != nil {
            throw LocalPanelFile.Issue.rawDecode
        }
        throw lastError
    }
}
