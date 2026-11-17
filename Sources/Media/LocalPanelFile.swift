import CoreImage
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// Which iPhone picker a screen asked for.
enum LocalPanelPicker: Equatable {
    case photos, files, presentationPDF

    static func homeAction(_ command: String?) -> Self? {
        switch command {
        case "files":
            return .files
        case "photos":
            return .photos
        default:
            return nil
        }
    }
}

/// Holds an open-in-place Files grant or a temporary Photos export.
final class LocalPanelFile {
    enum Kind: Equatable { case image, movie, document }
    enum Issue: LocalizedError {
        case unsupported, inaccessible, rawDecode
        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This file type can’t be opened in a screen."
            case .inaccessible:
                return "The selected item could not be read."
            case .rawDecode:
                return "This RAW photo couldn’t be rendered. Try exporting it as a JPEG in Photos."
            }
        }
    }

    let id = UUID()
    let url: URL
    let title: String
    let kind: Kind
    let sourceName: String
    let diagnosticType: String
    var isPresentation: Bool { ["ppt", "pptx"].contains(url.pathExtension.lowercased()) }
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
    private let securityScope: Bool
    private let photoDirectory: URL?

    private static let images: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "avif", "bmp"
    ]
    private static let movies: Set<String> = ["mov", "mp4", "m4v", "webm", "mpg", "mpeg"]
    private static let documents: Set<String> = [
        "pdf", "txt", "rtf", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx"
    ]
    static let allowedFiles: [UTType] =
        [.image, .movie, .pdf, .plainText, .rtf] + documents.sorted().compactMap { UTType(filenameExtension: $0) }

    private static func kind(_ ext: String) -> Kind? {
        if images.contains(ext) {
            return .image
        }
        if movies.contains(ext) {
            return .movie
        }
        if documents.contains(ext) {
            return .document
        }
        return nil
    }

    private init(
        url: URL, kind: Kind, title: String, securityScope: Bool, sourceName: String? = nil, pickedType: UTType? = nil,
        photoDirectory: URL? = nil
    ) {
        self.url = url
        self.kind = kind
        self.title = title
        self.sourceName = sourceName ?? url.lastPathComponent
        diagnosticType = (pickedType ?? UTType(filenameExtension: url.pathExtension))?.identifier ?? "unknown"
        self.securityScope = securityScope
        self.photoDirectory = photoDirectory
    }

    deinit {
        if securityScope {
            url.stopAccessingSecurityScopedResource()
        }
        if let photoDirectory {
            try? FileManager.default.removeItem(at: photoDirectory)
        }
    }

    static func openOriginal(_ url: URL) throws -> LocalPanelFile {
        guard url.isFileURL, let kind = kind(url.pathExtension.lowercased()) else {
            throw Issue.unsupported
        }
        let scope = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                FileManager.default.isReadableFile(atPath: url.path)
            else {
                throw Issue.inaccessible
            }
            return LocalPanelFile(
                url: url, kind: kind, title: String(url.lastPathComponent.prefix(128)), securityScope: scope)
        } catch {
            if scope {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// For Photos movies this page and its video are in a dedicated temporary
    /// directory. WebKit receives one narrow read grant for both files.
    var moviePageURL: URL? {
        photoDirectory.flatMap { kind == .movie ? $0.appendingPathComponent("player.html") : nil }
    }

    var moviePageHTML: String? {
        guard kind == .movie else {
            return nil
        }
        let src = (moviePageURL != nil ? url.lastPathComponent : url.absoluteString)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; media-src file:; style-src 'unsafe-inline'">
            <title>Local video</title>
            <style>html,body{margin:0;background:black;width:100%;height:100%;overflow:hidden}
            video{display:block;width:100%;height:100%;object-fit:contain}</style>
            <video src="\(src)" controls playsinline preload="metadata"></video>
            """
    }

    func matches(_ other: URL?) -> Bool {
        guard let other, other.isFileURL else {
            return false
        }
        let path = other.standardizedFileURL.resolvingSymlinksInPath()
        return [url, moviePageURL].compactMap { $0 }.contains {
            $0.standardizedFileURL.resolvingSymlinksInPath() == path
        }
    }

    private static var photoRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ViturePickedPhotos", isDirectory: true)
    }

    static func purgeOldPhotoExports() {
        try? FileManager.default.removeItem(at: photoRoot)
    }

    // The provider deletes its transfer URL at the end of the callback.
    // Keep a temporary export of ordinary assets; for RAW, keep only a preview.
    static func stagePhotoTransfer(_ file: URL, type: UTType, suggestedName: String? = nil) throws -> LocalPanelFile {
        let ext = file.pathExtension.lowercased()
        let fileType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let raw = type.conforms(to: .rawImage) || fileType?.conforms(to: .rawImage) == true || ext == "dng"
        let chosenExtension = kind(ext) != nil ? ext : type.preferredFilenameExtension ?? ext
        let kind = raw ? Kind.image : kind(chosenExtension)
        guard let kind, kind != .document else {
            throw Issue.unsupported
        }
        let dir = photoRoot.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        let temporary = dir.appendingPathComponent("photo." + (raw ? "jpg" : chosenExtension))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if raw {
                try writeRAWPreview(file, to: temporary)
            } else {
                try FileManager.default.copyItem(at: file, to: temporary)
            }
            let result = LocalPanelFile(
                url: temporary, kind: kind, title: kind == .movie ? "Photos video" : "Photo",
                securityScope: false, sourceName: suggestedName ?? file.lastPathComponent, pickedType: type,
                photoDirectory: dir)
            if let page = result.moviePageURL, let html = result.moviePageHTML {
                try html.write(to: page, atomically: true, encoding: .utf8)
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func writeRAWPreview(_ file: URL, to destination: URL) throws {
        let maxSide = 4096
        var preview: CGImage?
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
            let options =
                [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide
                ] as CFDictionary
            preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
        if preview == nil, let raw = CIRAWFilter(imageURL: file) {
            let extent = raw.nativeSize
            let largestSide = max(extent.width, extent.height)
            if largestSide.isFinite, largestSide > 0 {
                raw.scaleFactor = Float(min(1, CGFloat(maxSide) / largestSide))
            }
            if let image = raw.outputImage, !image.extent.isEmpty {
                preview = CIContext().createCGImage(image, from: image.extent)
            }
        }
        guard let preview,
            let encoder = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw Issue.rawDecode
        }
        CGImageDestinationAddImage(encoder, preview, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else {
            throw Issue.rawDecode
        }
    }
}
