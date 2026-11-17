import AVFoundation
import CoreImage
import MetalKit

/// Aggregate luminance only. Neither images, per-cell values, nor file names go in the report.
enum MediaLuma {
    static let columns = 32, rows = 18
    private static let subsamples = 4
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return bytes.allSatisfy { (32...126).contains($0) }
            ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", value)
    }

    static func description(_ buffer: CVPixelBuffer) -> String {
        let planes = CVPixelBufferGetPlaneCount(buffer)
        let strides =
            planes == 0
            ? String(CVPixelBufferGetBytesPerRow(buffer))
            : (0..<planes).map { String(CVPixelBufferGetBytesPerRowOfPlane(buffer, $0)) }.joined(separator: "/")
        func attachment(_ name: CFString) -> String {
            guard let text = CVBufferCopyAttachment(buffer, name, nil) as? String else {
                return "-"
            }
            return String(text.prefix(42))
        }
        let pixelFormat = fourCC(CVPixelBufferGetPixelFormatType(buffer))
        let size = "\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))"
        let hasIOSurface = CVPixelBufferGetIOSurface(buffer) != nil
        let colorKeys = [
            kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey
        ]
        let color = colorKeys.map(attachment).joined(separator: "/")
        return "\(pixelFormat) \(size) stride=\(strides) planes=\(planes) IOSurface=\(hasIOSurface) color=\(color)"
    }

    static func usesDirectCopy(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA && !CVPixelBufferIsPlanar(buffer)
    }

    static func convertedImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    static func grid(_ buffer: CVPixelBuffer) -> [Double]? {
        if !usesDirectCopy(buffer) {
            return convertedImage(buffer).flatMap { grid($0) }
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= width * 4 else {
            return nil
        }
        return reduced(width: width, height: height) { y, x in
            let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            return luma(b: pixel[0], g: pixel[1], r: pixel[2])
        }
    }

    static func grid(_ image: CGImage) -> [Double]? {
        let scale = min(1, 2048.0 / Double(max(1, max(image.width, image.height))))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress,
                let canvas = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else {
                return nil
            }
            canvas.interpolationQuality = .medium
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return reduced(width: width, height: height) { y, x in
                let pixel = base.advanced(by: (y * width + x) * 4).assumingMemoryBound(to: UInt8.self)
                return luma(b: pixel[2], g: pixel[1], r: pixel[0])
            }
        }
    }

    static func grid(_ texture: MTLTexture) -> [Double]? {
        let bgra = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb
        guard bgra || texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb,
            texture.storageMode == .shared
        else {
            return nil
        }
        let stride = texture.width * 4
        var row = [UInt8](repeating: 0, count: stride)
        var cachedY = -1
        return reduced(width: texture.width, height: texture.height) { y, x in
            if cachedY != y {
                texture.getBytes(
                    &row, bytesPerRow: stride, from: MTLRegionMake2D(0, y, texture.width, 1), mipmapLevel: 0)
                cachedY = y
            }
            let pixel = x * 4
            return luma(b: row[pixel + (bgra ? 0 : 2)], g: row[pixel + 1], r: row[pixel + (bgra ? 2 : 0)])
        }
    }

    /// Reads a paused, CPU-visible upload without applying the display shader.
    static func image(_ texture: MTLTexture) -> CGImage? {
        let bgra = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb
        guard bgra || texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb,
            texture.storageMode == .shared, texture.width > 0, texture.height > 0
        else {
            return nil
        }
        let stride = texture.width * 4
        var bytes = Data(count: stride * texture.height)
        bytes.withUnsafeMutableBytes { storage in
            if let address = storage.baseAddress {
                texture.getBytes(
                    address, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else {
            return nil
        }
        let alpha = bgra ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.noneSkipLast
        let order: CGBitmapInfo = bgra ? .byteOrder32Little : .byteOrder32Big
        return CGImage(
            width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace, bitmapInfo: order.union(CGBitmapInfo(rawValue: alpha.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func difference(_ lhs: [Double]?, _ rhs: [Double]?) -> String {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else {
            return "unavailable"
        }
        let deltas = zip(lhs, rhs).map { abs($0 - $1) }
        return String(
            format: "mean %.2f, max %.2f / 255", deltas.reduce(0, +) / Double(deltas.count), deltas.max() ?? 0)
    }

    private static func luma(b: UInt8, g: UInt8, r: UInt8) -> Double {
        0.0722 * Double(b) + 0.7152 * Double(g) + 0.2126 * Double(r)
    }

    private static func reduced(width: Int, height: Int, pixel: (Int, Int) -> Double) -> [Double]? {
        guard width > 0, height > 0 else {
            return nil
        }
        // Walk across each sampled row so texture readback requires only one GPU row per y.
        var result = [Double](repeating: 0, count: columns * rows)
        for y in 0..<(rows * subsamples) {
            let py = min(height - 1, (2 * y + 1) * height / (2 * rows * subsamples))
            for x in 0..<(columns * subsamples) {
                let px = min(width - 1, (2 * x + 1) * width / (2 * columns * subsamples))
                result[(y / subsamples) * columns + x / subsamples] += pixel(py, px)
            }
        }
        return result.map { $0 / Double(subsamples * subsamples) }
    }
}
