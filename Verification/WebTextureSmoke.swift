import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import SpatialMath
import UniformTypeIdentifiers

@main
struct WebTextureSmoke {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            fatalError("Input image or Metal missing")
        }
        let renderer = try WebSnapshotRenderer(device: device)
        print(String(format: "Mac snapshot texture upload: %.2f ms", try renderer.upload(image)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1920, height: 600, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let command = renderer.queue.makeCommandBuffer()!
        guard
            renderer.encode(
                command: command, pass: pass, size: CGSize(width: 1920, height: 600), frame: RenderFrame(stereo: true))
        else {
            fatalError("No encoder")
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        var pixels = [UInt8](repeating: 0, count: 1920 * 600 * 4)
        texture.getBytes(&pixels, bytesPerRow: 1920 * 4, from: MTLRegionMake2D(0, 0, 1920, 600), mipmapLevel: 0)
        let white = stride(from: 0, to: pixels.count, by: 4).filter {
            min(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 220
        }.count
        guard white > 10000 else {
            fatalError("Web texture is blank")
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmap = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let cg = CGImage(
            width: 1920, height: 600, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1920 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let out = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, cg, nil);
        guard CGImageDestinationFinalize(out) else {
            fatalError("PNG export failed")
        }
        print(
            "Mac actual Metal snapshot pipeline passed: \(white) light pixels, dual eye texture views. Not an iPhone result."
        )
    }
}
