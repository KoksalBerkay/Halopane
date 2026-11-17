import AVFoundation
import CoreImage
import MetalKit

/// One paused frame, kept to compare the phone with the glasses.
struct PausedMediaComparison {
    let id = UUID()
    let timestamp: CMTime
    let left: CGImage
    let right: CGImage?
    let leftTexture: MTLTexture
    let rightTexture: MTLTexture?
    let turns: UInt32

    var timeLabel: String { timestamp.isNumeric ? String(format: "%.3f s", timestamp.seconds) : "unknown time" }
}

/// Which path draws the compared frame in the glasses.
enum ComparisonGlassesRoute: String, CaseIterable, Identifiable {
    case metal = "Metal", image = "Image view"
    var id: Self { self }
}

/// Collects decoding and display details for the media diagnostics report.
final class NativeMediaDiagnostics {
    struct Pair {
        let left: CVPixelBuffer
        let right: CVPixelBuffer?
        let timestamp: CMTime
        let leftTexture: MTLTexture?
        let rightTexture: MTLTexture?
        let route: String
        var leftImage: CGImage? = nil
        var rightImage: CGImage? = nil
    }

    private var id = UUID()
    private let worker = DispatchQueue(label: "local.viture.media-diagnostics", qos: .utility)
    private var pendingGrid = false
    private var entries: [String] = []
    private var format = ""
    private var history: [String] = []
    private(set) var last: Pair?
    private var both = 0, single = 0, failures = 0
    private var display = "not drawn"

    func start(_ source: LocalPanelFile, decoder: String) {
        id = UUID()
        entries = []
        last = nil
        both = 0
        single = 0
        failures = 0
        display = "not drawn"
        let size = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(String.init) ?? "-"
        format = "source=\(source.diagnosticType), bytes=\(size), output request=\(decoder)"
    }

    func videoFormat(_ text: String) {
        format += "\n" + text
    }
    func screen(_ size: CGSize, stereo: Bool, eyes: StereoEyePreview, route: String = "Metal") {
        let mode =
            "\(Int(size.width))×\(Int(size.height)), \(stereo ? "SBS" : "2D"), "
            + "eyes=\(eyes.rawValue), route=\(route)"
        if display != mode {
            if display != "not drawn" {
                entries = Array((entries + ["Display changed to " + mode]).suffix(9))
            }
            display = mode
        }
    }

    func record(_ pair: Pair, frame: Int, expectedStereo: Bool) {
        if pair.right != nil {
            both += 1
        } else {
            single += 1
        }
        let leftOK = pair.leftTexture != nil || pair.leftImage != nil
        let rightOK = pair.rightTexture != nil || pair.rightImage != nil
        if !leftOK || (expectedStereo && !rightOK) {
            failures += 1
        }
        if leftOK, (!expectedStereo || rightOK) {
            last = pair
        }
        guard (frame == 1 || frame % 30 == 0), !pendingGrid else {
            return
        }
        let id = id
        pendingGrid = true
        let prefix =
            "\(frame) @ \(stamp(pair.timestamp)): \(pair.route); L \(MediaLuma.description(pair.left))"
            + (pair.right.map { "; R \(MediaLuma.description($0))" } ?? (expectedStereo ? "; no right buffer" : ""))
        // Do not retain textures for automatic sampling; the decoded pair alone is sufficient.
        let left = pair.left, right = pair.right
        worker.async { [weak self] in
            let delta = right.map { MediaLuma.difference(MediaLuma.grid(left), MediaLuma.grid($0)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.pendingGrid = false
                if self.id == id {
                    self.append(prefix + (delta.map { "; L/R \($0)" } ?? ""))
                }
            }
        }
    }

    func compare(turns: UInt32, complete: @escaping (PausedMediaComparison?) -> Void) {
        guard let pair = last else {
            complete(nil)
            return
        }
        let run = id
        worker.async { [weak self] in
            let left = pair.leftImage ?? pair.leftTexture.flatMap { MediaLuma.image($0) }
            let right = pair.rightImage ?? pair.rightTexture.flatMap { MediaLuma.image($0) }
            let textureLoader = (pair.leftTexture == nil ? MTLCreateSystemDefaultDevice() : nil).map {
                MTKTextureLoader(device: $0)
            }
            func upload(_ image: CGImage) -> MTLTexture? {
                try? textureLoader?.newTexture(
                    cgImage: image,
                    options: [
                        .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                        .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
                    ])
            }
            let texture = pair.leftTexture ?? left.flatMap(upload)
            let rightTexture = pair.rightTexture ?? right.flatMap(upload)
            let comparison: PausedMediaComparison?
            if let left, let texture {
                comparison = PausedMediaComparison(
                    timestamp: pair.timestamp, left: left, right: right, leftTexture: texture,
                    rightTexture: rightTexture, turns: turns)
            } else {
                comparison = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.id == run else {
                    return
                }
                if let comparison {
                    self.append("Paused frame comparison latched at " + comparison.timeLabel, priority: true)
                }
                complete(comparison)
            }
        }
    }

    func comparisonRoute(_ route: ComparisonGlassesRoute, eye: StereoEyePreview) {
        append("Paused frame comparison: \(route.rawValue), \(eye.rawValue)", priority: true)
    }

    func check(file: LocalPanelFile, complete: @escaping (String) -> Void) {
        guard let pair = last else {
            complete("Play until a picture appears, then pause and check again.")
            return
        }
        let run = id
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let generated = await Self.reference(file: file, at: pair.timestamp)
            let frameTime = self.stamp(pair.timestamp)
            let result: String = await withCheckedContinuation { finish in
                self.worker.async {
                    let left = MediaLuma.grid(pair.left)
                    let right = pair.right.flatMap { MediaLuma.grid($0) }
                    let uploadedLeft =
                        pair.leftImage.flatMap { MediaLuma.grid($0) }
                        ?? pair.leftTexture.flatMap { MediaLuma.grid($0) }
                    let uploadedRight =
                        pair.rightImage.flatMap { MediaLuma.grid($0) }
                        ?? pair.rightTexture.flatMap { MediaLuma.grid($0) }
                    let target = pair.leftImage != nil ? "image" : "texture"
                    var text =
                        "Check @ \(frameTime), \(pair.route)\n"
                        + "  decoded→\(target) L: \(MediaLuma.difference(left, uploadedLeft)); "
                        + "R: \(MediaLuma.difference(right, uploadedRight))"
                    if let generated {
                        let reference = MediaLuma.grid(generated.image)
                        let delta = (generated.actualTime - pair.timestamp).seconds
                        text +=
                            "\n  generator Δt \(String(format: "%.4f", delta)) s; "
                            + "vs decoded L: \(MediaLuma.difference(reference, left)); "
                            + "R: \(MediaLuma.difference(reference, right))"
                    } else {
                        text += "\n  generator reference unavailable at this exact presentation time"
                    }
                    finish.resume(returning: text)
                }
            }
            guard self.id == run else {
                return
            }
            self.append(result, priority: true)
            complete("Frame checked. Results are in the media report.")
        }
    }

    private static func reference(file: LocalPanelFile, at time: CMTime) async -> (
        image: CGImage, actualTime: CMTime
    )? {
        guard time.isNumeric else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
        generator.appliesPreferredTrackTransform = false
        generator.apertureMode = .encodedPixels
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640)
        return try? await generator.image(at: time)
    }

    private var first = ""
    private var checks: [String] = []
    private func append(_ text: String, priority: Bool = false) {
        if priority {
            checks = Array((checks + [text]).suffix(4))
            return
        }
        if first.isEmpty {
            first = text
        } else {
            entries = Array((entries + [text]).suffix(9))
        }
    }

    var report: String {
        let active = format.isEmpty ? [] : [current]
        if history.isEmpty && active.isEmpty {
            return "No media runs captured."
        }
        return (history + active).enumerated().map { "Run \($0.offset+1)\n\($0.element)" }.joined(separator: "\n\n")
    }
    private var current: String {
        ([format, "output: \(display); pairs=\(both), single=\(single), upload failures=\(failures)"]
            + (first.isEmpty ? [] : [first]) + entries + checks).joined(separator: "\n")
    }
    func finish() {
        if !format.isEmpty {
            history = Array((history + [current]).suffix(5))
        }
        id = UUID()
        format = ""
        entries = []
        first = ""
        checks = []
        last = nil
    }
    private func stamp(_ time: CMTime) -> String {
        time.isNumeric ? String(format: "%.3f s", time.seconds) : "unknown PTS"
    }
}
