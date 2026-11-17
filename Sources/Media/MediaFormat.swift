import AVFoundation
import ImageIO

/// Flat, 180 degree or 360 degree media.
enum MediaProjection: UInt32, CaseIterable, Identifiable {
    case flat, halfSphere, sphere
    var id: Self { self }
    var title: String {
        switch self {
        case .flat:
            return "Flat"
        case .halfSphere:
            return "180°"
        case .sphere:
            return "360°"
        }
    }
}

/// How the two eyes are stored: one image, side by side, over-under, or separate tracks.
enum MediaArrangement: UInt32, CaseIterable, Identifiable {
    case mono, sideBySide, halfSideBySide, overUnder, halfOverUnder, separateEyes
    var id: Self { self }
    var title: String {
        switch self {
        case .mono:
            return "Mono"
        case .sideBySide:
            return "Side by side"
        case .halfSideBySide:
            return "Half side by side"
        case .overUnder:
            return "Over-under"
        case .halfOverUnder:
            return "Half over-under"
        case .separateEyes:
            return "Spatial stereo"
        }
    }
}

/// Projection and eye layout, guessed from the file name and read from metadata.
struct MediaFormat {
    var projection: MediaProjection = .flat
    var layout: MediaArrangement = .mono

    static func inferred(from filename: String) -> Self {
        let words = Set(filename.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var format = Self()
        if !words.isDisjoint(with: ["360", "360vr", "vr360"]) {
            format.projection = .sphere
        } else if !words.isDisjoint(with: ["180", "180vr", "vr180"]) {
            format.projection = .halfSphere
        }
        if words.contains("hsbs") || (words.contains("half") && words.contains("sbs")) {
            format.layout = .halfSideBySide
        } else if words.contains("htab") || words.contains("hou") {
            format.layout = .halfOverUnder
        } else if !words.isDisjoint(with: ["sbs", "lr"]) {
            format.layout = .sideBySide
        } else if !words.isDisjoint(with: ["ou", "tb", "tab"]) {
            format.layout = .overUnder
        }
        return format
    }

    var needsSpatialPlayer: Bool { projection != .flat || layout != .mono }

    static func prefersSpatialPlayer(for file: LocalPanelFile) async -> Bool {
        guard file.kind != .document else {
            return false
        }
        let hints = inferred(from: file.sourceName)
        if hints.needsSpatialPlayer {
            return true
        }
        if file.kind == .image {
            return await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else {
                    return false
                }
                return NativePhotoFrames.eyeIndices(source) != nil || NativePhotoFrames.projection(source) != nil
            }.value
        }
        let asset = AVURLAsset(url: file.url)
        if #available(iOS 17.2, *),
            let tracks = try? await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo),
            !tracks.isEmpty
        {
            return true
        }
        if #available(iOS 18.0, macOS 15.0, *),
            let tracks = try? await asset.loadTracks(withMediaType: .video)
        {
            for track in tracks {
                guard let descriptions = try? await track.load(.formatDescriptions) else {
                    continue
                }
                for description in descriptions {
                    var format = hints
                    format.applyVideoMetadata(description)
                    if format.needsSpatialPlayer {
                        return true
                    }
                }
            }
        }
        return false
    }

    @available(iOS 18.0, macOS 15.0, *)
    mutating func applyVideoMetadata(_ description: CMFormatDescription) {
        let properties = CMFormatDescriptionGetExtensions(description) as? [CFString: Any]
        let shape = properties?[kCMFormatDescriptionExtension_ProjectionKind] as? String
        if shape == kCMFormatDescriptionProjectionKind_Equirectangular as String {
            projection = .sphere
        } else if shape == kCMFormatDescriptionProjectionKind_HalfEquirectangular as String {
            projection = .halfSphere
        }
        let packing = properties?[kCMFormatDescriptionExtension_ViewPackingKind] as? String
        if packing == kCMFormatDescriptionViewPackingKind_SideBySide as String, layout != .halfSideBySide {
            layout = .sideBySide
        } else if packing == kCMFormatDescriptionViewPackingKind_OverUnder as String, layout != .halfOverUnder {
            layout = .overUnder
        }
    }
}
