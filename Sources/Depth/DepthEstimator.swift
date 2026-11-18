import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// One depth map from the model, with a small grayscale thumbnail of the same
/// frame for spotting scene cuts. `raw` is relative depth: larger is nearer.
struct DepthEstimate {
    let raw: [Float]
    let width: Int
    let height: Int
    let thumbnail: [UInt8]
    let milliseconds: Double
}

/// Runs the bundled depth model, Depth Anything V2 Small, on the Neural Engine.
/// One instance serves every screen. The model loads on first use, which takes
/// a few seconds the first time while the system compiles it for this iPhone.
final class DepthEstimator: ObservableObject {
    static let shared = DepthEstimator()
    /// Only the Small model is Apache 2.0. The larger Depth Anything V2 models are
    /// non-commercial and must not replace it. See ThirdParty/Depth-Anything-V2-NOTICE.md.
    static let modelName = "DepthAnythingV2SmallF16P6"
    /// The model takes one fixed size. Frames are stretched to it, as in Apple's evaluation.
    static let inputWidth = 518
    static let inputHeight = 392
    static let thumbnailWidth = 32
    static let thumbnailHeight = 24

    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    @Published private(set) var state = State.idle
    private(set) var loadSeconds: Double?
    private let queue = DispatchQueue(label: "local.viture.depth-estimator", qos: .userInitiated)
    private let modelURL: URL?
    // Only touched on `queue`.
    private var model: MLModel?
    private var inputName = "image"
    private var outputName = "depth"
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(modelURL: URL? = Bundle.main.url(forResource: DepthEstimator.modelName, withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    /// Starts loading the model if it is not loaded yet. Safe to call often.
    func prepare() {
        guard state == .idle || state.isFailure else {
            return
        }
        state = .loading
        queue.async { [weak self] in
            guard let self else {
                return
            }
            let start = CACurrentMediaTime()
            let result = self.loadModel()
            let seconds = CACurrentMediaTime() - start
            DispatchQueue.main.async {
                self.loadSeconds = seconds
                self.state = result
            }
        }
    }

    /// Estimates depth for a decoded video frame in any pixel format.
    func estimate(_ frame: CVPixelBuffer, completion: @escaping (DepthEstimate?) -> Void) {
        queue.async { [weak self] in
            let estimate = self.flatMap { estimator in
                estimator.makeInput().flatMap { input in
                    estimator.scale(frame, into: input) ? estimator.run(input) : nil
                }
            }
            DispatchQueue.main.async {
                completion(estimate)
            }
        }
    }

    /// Estimates depth for a still image or a page snapshot.
    func estimate(_ image: CGImage, completion: @escaping (DepthEstimate?) -> Void) {
        queue.async { [weak self] in
            let estimate = self.flatMap { estimator in
                estimator.makeInput().flatMap { input in
                    estimator.draw(image, into: input) ? estimator.run(input) : nil
                }
            }
            DispatchQueue.main.async {
                completion(estimate)
            }
        }
    }

    // MARK: Model

    private func loadModel() -> State {
        guard var url = modelURL else {
            return .failed("The depth model is missing from this build.")
        }
        do {
            // The Mac checks pass the source package; the app bundle holds the compiled model.
            if url.pathExtension == "mlpackage" {
                url = try MLModel.compileModel(at: url)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let loaded = try MLModel(contentsOf: url, configuration: configuration)
            let description = loaded.modelDescription
            if let name = description.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key {
                inputName = name
            }
            if let name = description.outputDescriptionsByName.first(where: { $0.value.type == .image })?.key {
                outputName = name
            }
            model = loaded
            // The first prediction is much slower than the rest, so pay for it now.
            if let input = makeInput() {
                _ = run(input)
            }
            return .ready
        } catch {
            return .failed("The depth model could not load: " + error.localizedDescription)
        }
    }

    private func run(_ input: CVPixelBuffer) -> DepthEstimate? {
        guard let model else {
            return nil
        }
        let start = CACurrentMediaTime()
        guard
            let features = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)]
            ),
            let output = try? model.prediction(from: features),
            let depth = output.featureValue(for: outputName)?.imageBufferValue,
            let raw = Self.floats(from: depth)
        else {
            return nil
        }
        return DepthEstimate(
            raw: raw.values, width: raw.width, height: raw.height, thumbnail: Self.thumbnail(of: input),
            milliseconds: (CACurrentMediaTime() - start) * 1000)
    }

    // MARK: Input frames

    private func makeInput() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.inputWidth,
                kCVPixelBufferHeightKey as String: Self.inputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else {
            return nil
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    // VideoToolbox scales and converts YUV or 10-bit frames in one hardware pass.
    private func scale(_ frame: CVPixelBuffer, into input: CVPixelBuffer) -> Bool {
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(
                    transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            }
        }
        guard let transfer else {
            return false
        }
        return VTPixelTransferSessionTransferImage(transfer, from: frame, to: input) == noErr
    }

    private func draw(_ image: CGImage, into input: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess else {
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(input, [])
        }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(input), width: Self.inputWidth, height: Self.inputHeight,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(input),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else {
            return false
        }
        context.interpolationQuality = .medium
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Self.inputWidth, height: Self.inputHeight))
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.inputWidth, height: Self.inputHeight))
        return true
    }

    // MARK: Conversions

    /// Reads the model's half-float depth image as floats.
    private static func floats(from depth: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent16Half,
            CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess
        else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        }
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else {
            return nil
        }
        var values = [Float](repeating: 0, count: width * height)
        let converted = values.withUnsafeMutableBytes { out -> vImage_Error in
            var source = vImage_Buffer(
                data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRow(depth))
            var destination = vImage_Buffer(
                data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: width * MemoryLayout<Float>.stride)
            return vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
        }
        guard converted == kvImageNoError else {
            return nil
        }
        return (values, width, height)
    }

    /// Samples a small grayscale picture of the model input.
    private static func thumbnail(of input: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else {
            return []
        }
        defer {
            CVPixelBufferUnlockBaseAddress(input, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(input)?.assumingMemoryBound(to: UInt8.self) else {
            return []
        }
        let stride = CVPixelBufferGetBytesPerRow(input)
        var out = [UInt8]()
        out.reserveCapacity(thumbnailWidth * thumbnailHeight)
        for row in 0..<thumbnailHeight {
            let y = (row * 2 + 1) * inputHeight / (thumbnailHeight * 2)
            for column in 0..<thumbnailWidth {
                let x = (column * 2 + 1) * inputWidth / (thumbnailWidth * 2)
                let pixel = base + y * stride + x * 4
                // BGRA order. Integer Rec. 601 weights.
                let luma = (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
                out.append(UInt8(luma))
            }
        }
        return out
    }
}

extension DepthEstimator.State {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
