import AVFoundation

/// Show both eyes, or only the left or right eye, for checking.
enum StereoEyePreview: String, CaseIterable, Identifiable {
    case stereo = "Both eyes", leftOnly = "Left only", rightOnly = "Right only"
    var id: Self { self }
}

/// Draw 3D video with Metal or as images.
enum StereoPresentationRoute: String, CaseIterable, Identifiable {
    case image = "Image surface", metal = "Metal"
    var id: Self { self }
}

/// Which decoder reads MV-HEVC 3D video.
enum StereoDecoderChoice: String, CaseIterable, Identifiable {
    case trackReader = "Stereo track reader"
    case playerNative = "Player output · native format"
    case playerBGRA = "Player output · BGRA"
    var id: Self { self }
}

/// Reads both eyes of an MV-HEVC video from AVPlayer.
@available(iOS 17.2, *)
final class NativeStereoOutput {
    let output: AVPlayerVideoOutput

    init(player: AVPlayer, attributes: [String: Any]) {
        let specification = AVVideoOutputSpecification(tagCollections: [
            .stereoscopicForVideoOutput(), .monoscopicForVideoOutput()
        ])
        specification.defaultPixelBufferAttributes = attributes
        output = AVPlayerVideoOutput(specification: specification)
        player.videoOutput = output
    }

    func sample(time: CFTimeInterval) -> (CVPixelBuffer, CVPixelBuffer?, CMTime)? {
        guard
            let sample = output.taggedBuffers(forHostTime: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
        else {
            return nil
        }
        guard
            let frame = StereoDecodedFrame.read(
                sample.taggedBufferGroup, at: sample.presentationTime, requirePair: false)
        else {
            return nil
        }
        return (frame.left, frame.right, frame.time)
    }
}
