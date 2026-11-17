import AVFoundation
import ImageIO

/// Video track details, read from the file before playback starts.
struct LoadedVideoTrack {
    let track: AVAssetTrack
    let isStereo: Bool
    let transform: CGAffineTransform
    let description: CMFormatDescription?
    let nominalFrameRate: Float
    let duration: CMTime

    /// Prefers an MV-HEVC stereo track and falls back to the first video track.
    static func load(from asset: AVURLAsset) async throws -> LoadedVideoTrack {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let stereoTrack: AVAssetTrack?
        if #available(iOS 17.2, *) {
            stereoTrack = try? await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
                .first
        } else {
            stereoTrack = nil
        }
        guard let track = stereoTrack ?? videoTracks.first else {
            throw NativeMediaSession.MediaError.noVideo
        }
        let transform = try await track.load(.preferredTransform)
        let description = try? await track.load(.formatDescriptions).first
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let duration = (try? await asset.load(.duration)) ?? .invalid
        return LoadedVideoTrack(
            track: track,
            isStereo: stereoTrack != nil,
            transform: transform,
            description: description,
            nominalFrameRate: nominalFrameRate,
            duration: duration)
    }

    /// The preferred rotation rounded to a whole number of quarter turns (0 to 3).
    var quarterTurns: UInt32 {
        let angle = atan2(transform.b, transform.a)
        guard angle.isFinite else {
            return 0
        }
        let turns = Int((angle / (.pi / 2)).rounded())
        return UInt32((turns + 4) % 4)
    }

    var componentBits: Int? {
        let extensions = description.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] }
        let bits = extensions?[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber
        return bits?.intValue
    }

    /// Layer IDs of the views in an MV-HEVC track. A stereo track has two.
    @available(iOS 17.2, *)
    var videoLayerIDs: [Int64] {
        let tags = description?.tagCollections?.flatMap { $0 } ?? []
        let layerIDs = tags.compactMap { $0.value(onlyIfMatching: .videoLayerID) }
        return Array(Set(layerIDs)).sorted()
    }
}

/// A photo read from a file, ready to show.
struct DecodedPhoto {
    /// Left image and, for spatial photos, the right image.
    let frames: (CGImage, CGImage?)?
    let projection: MediaProjection

    /// Reads the photo off the main thread. Panoramas keep a larger size than flat photos.
    static func decode(_ file: LocalPanelFile, inferredProjection: MediaProjection) async -> DecodedPhoto {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else {
                return DecodedPhoto(frames: nil, projection: inferredProjection)
            }
            var projection = inferredProjection
            if projection == .flat {
                projection = NativePhotoFrames.projection(source) ?? .flat
            }
            let maxSide = projection == .flat ? 4096 : 6144
            let frames = NativePhotoFrames.read(source, maxSide: maxSide)
            return DecodedPhoto(frames: frames, projection: projection)
        }.value
    }
}
