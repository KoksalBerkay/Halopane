import AVFoundation
import CoreImage

/// A 3D video frame converted to two images.
struct LiveStereoImageFrame {
    let id = UUID()
    let timestamp: CMTime
    let left: CGImage
    let right: CGImage
    let turns: UInt32
}

/// One conversion at a time, always from a single tagged pair. If conversion
/// runs behind, the next display callback asks for the current player time.
final class LiveStereoImageOutput {
    private let queue = DispatchQueue(label: "local.viture.live-stereo-images", qos: .userInitiated)
    private var id: UUID?
    private var busy = false
    private var timestamp = CMTime.invalid
    private(set) var frame: LiveStereoImageFrame?

    func clear() {
        id = nil
        timestamp = .invalid
        frame = nil
    }

    func update(session: NativeMediaSession, hostTime: CFTimeInterval) {
        if id != session.renderID {
            clear()
            id = session.renderID
        }
        guard !busy, let request = id,
            let sample = session.sample(hostTime: hostTime, after: timestamp)
        else {
            return
        }
        timestamp = sample.2
        busy = true
        let turns = session.quarterTurns
        let count = session.decodedVideoFrames
        queue.async { [weak self, weak session] in
            let left = MediaLuma.convertedImage(sample.0)
            let right = sample.1.flatMap { MediaLuma.convertedImage($0) }
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self else {
                    return
                }
                self.busy = false
                guard let session, self.id == request, request == session.renderID,
                    session.usesLiveImagePresentation,
                    session.comparison == nil
                else {
                    return
                }
                if let left, let right {
                    self.frame = LiveStereoImageFrame(timestamp: sample.2, left: left, right: right, turns: turns)
                }
                session.diagnostics.record(
                    .init(
                        left: sample.0, right: sample.1, timestamp: sample.2,
                        leftTexture: nil, rightTexture: nil, route: "live image surface", leftImage: left,
                        rightImage: right),
                    frame: count, expectedStereo: true)
            }
        }
    }
}
