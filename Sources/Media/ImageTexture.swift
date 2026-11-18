import CoreGraphics
import Metal

/// Turns a decoded image into a BGRA Metal texture.
///
/// MTKTextureLoader swaps red and blue for JPEGs decoded without alpha, so
/// those photos turn blue, and it refuses 10-bit and 16-bit photos. Core
/// Graphics draws every image into one known 8-bit layout first instead.
enum ImageTexture {
    static func make(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let layout = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: space, bitmapInfo: layout)
            else {
                return false
            }
            // The first row in memory is the top of the picture.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }
}
