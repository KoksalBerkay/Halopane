import AVFoundation
import VideoToolbox

/// One decoded frame with both eyes.
struct StereoDecodedFrame {
    let left: CVPixelBuffer
    let right: CVPixelBuffer?
    let time: CMTime

    @available(iOS 17.0, macOS 14.0, *)
    static func read(_ buffers: [CMTaggedBuffer], at time: CMTime, requirePair: Bool) -> Self? {
        var left: CVPixelBuffer?
        var right: CVPixelBuffer?
        var first: CVPixelBuffer?
        for tagged in buffers {
            let pixels: CVPixelBuffer
            switch tagged.buffer {
            case .pixelBuffer(let buffer):
                pixels = buffer
            case .sampleBuffer(let sample):
                guard let buffer = sample.imageBuffer else {
                    continue
                }
                pixels = buffer
            @unknown default: continue
            }
            first = first ?? pixels
            let view = tagged.tags.firstValue(matchingCategory: .stereoView)
            if view == .leftEye {
                left = pixels
            } else if view == .rightEye {
                right = pixels
            }
        }
        if requirePair, (left == nil || right == nil) {
            return nil
        }
        guard let primary = left ?? first else {
            return nil
        }
        return Self(left: primary, right: left == nil ? nil : right, time: time)
    }
}

/// Reads one tagged stereo track ahead of the player clock. The clock and audio
/// stay with AVPlayer. Reader operations run on a serial queue; the display loop
/// only checks a small FIFO and never blocks on VideoToolbox.
@available(iOS 17.2, macOS 14.2, *)
final class StereoTrackReader {
    private let fileLease: LocalPanelFile
    private let asset: AVAsset
    private let track: AVAssetTrack
    let layers: [Int64]
    let pixelFormat: OSType
    private let duration: CMTime
    private let decode = DispatchQueue(label: "local.viture.stereo-reader", qos: .userInitiated)
    private let lock = NSLock()
    private let capacity = 5
    private let tolerance = CMTime(seconds: 0.022, preferredTimescale: 60_000)
    // Worker-owned.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    // Protected by the lock.
    private var revision: UInt64 = 0
    private var frames: [StereoDecodedFrame] = []
    private var scheduled = false
    private var terminal = false
    private var reason: String?

    init(file: LocalPanelFile, asset: AVAsset, track: AVAssetTrack, layers: [Int64], duration: CMTime, bits: Int) {
        fileLease = file
        self.asset = asset
        self.track = track
        self.layers = layers
        self.duration = duration
        pixelFormat =
            bits > 8
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    var failure: String? {
        lock.withLock { reason }
    }

    func seek(to time: CMTime) {
        let rev = lock.withLock {
            revision &+= 1
            frames = []
            reason = nil
            terminal = false
            scheduled = true
            return revision
        }
        decode.async { [weak self] in
            guard let self, self.isCurrent(rev) else {
                return
            }
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            do {
                let reader = try AVAssetReader(asset: self.asset)
                // Allow a short lead-in so the first displayed frame covers the requested time.
                // AVAssetReader handles the actual keyframe dependencies internally.
                let lead = CMTime(seconds: 0.07, preferredTimescale: 60_000)
                let start = CMTimeMaximum(.zero, time - lead)
                if start > .zero, self.duration.isNumeric, self.duration > start {
                    reader.timeRange = CMTimeRange(start: start, end: self.duration)
                }
                let options: [String: Any] = [
                    AVVideoDecompressionPropertiesKey: [
                        kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: self.layers
                    ],
                    kCVPixelBufferPixelFormatTypeKey as String: self.pixelFormat,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                let output = AVAssetReaderTrackOutput(track: self.track, outputSettings: options)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    self.end(rev, error: "could not configure stereo track output")
                    return
                }
                reader.add(output)
                guard reader.startReading() else {
                    self.end(rev, error: "could not start track read")
                    return
                }
                self.reader = reader
                self.output = output
                self.pump(rev)
            } catch {
                let error = error as NSError
                self.end(rev, error: "could not create track reader (\(error.domain) \(error.code))")
            }
        }
    }

    func frame(at time: CMTime) -> StereoDecodedFrame? {
        guard time.isNumeric else {
            return nil
        }
        let (frame, request) = lock.withLock { () -> (StereoDecodedFrame?, UInt64?) in
            let cutoff = time + tolerance
            var sample: StereoDecodedFrame?
            while let first = frames.first, first.time <= cutoff {
                let candidate = frames.removeFirst()
                if sample == nil || candidate.time >= sample!.time {
                    sample = candidate
                }
            }
            if !terminal, !scheduled, frames.count < capacity {
                scheduled = true
                return (sample, revision)
            }
            return (sample, nil)
        }
        if let request {
            decode.async { [weak self] in
                self?.pump(request)
            }
        }
        return frame
    }

    private func isCurrent(_ range: UInt64) -> Bool {
        lock.withLock { revision == range && !terminal }
    }

    private func end(_ rev: UInt64, error: String?) {
        lock.withLock {
            guard rev == revision else {
                return
            }
            terminal = true
            scheduled = false
            reason = error
        }
    }

    private func pump(_ rev: UInt64) {
        guard let reader, let output, isCurrent(rev) else {
            return
        }
        for _ in 0..<(capacity * 3) {
            let needsFrame = lock.withLock { revision == rev && !terminal && frames.count < capacity }
            guard needsFrame else {
                break
            }
            guard let sample = output.copyNextSampleBuffer() else {
                let error = reader.error as NSError?
                let issue =
                    reader.status == .failed
                    ? "track read failed (\(error?.domain ?? "AVFoundation") \(error?.code ?? 0))" : nil
                end(rev, error: issue)
                return
            }
            let time = sample.presentationTimeStamp
            guard time.isNumeric, let tags = sample.taggedBuffers,
                let frame = StereoDecodedFrame.read(tags, at: time, requirePair: true)
            else {
                end(rev, error: "track reader returned no tagged left/right pair")
                return
            }
            lock.withLock {
                if revision == rev, !terminal {
                    let i = frames.firstIndex(where: { $0.time > frame.time }) ?? frames.endIndex
                    frames.insert(frame, at: i)
                }
            }
        }
        lock.withLock {
            if revision == rev {
                scheduled = false
            }
        }
    }

    func stop() {
        lock.withLock {
            revision &+= 1
            frames = []
            terminal = true
            scheduled = false
        }
        decode.async { [self] in
            reader?.cancelReading()
            reader = nil
            output = nil
        }
    }
}
