import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import QuartzCore
import SpatialMath
import UniformTypeIdentifiers

/// Runs 2D-to-3D on the Mac: the bundled model, depth filtering, the mesh and
/// the Metal warp. Pass an image to convert it, or none for a drawn test scene.
/// Writes the two eyes side by side to a PNG for a visual check.
@main struct Depth3DSmoke {
    enum Check: Error {
        case failed(String)
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        let model = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        let image = try arguments.count > 3 ? loadImage(arguments[3]) : drawnScene()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Check.failed("Metal unavailable")
        }

        let estimator = DepthEstimator(modelURL: model)
        let conversion = StereoConversion(estimator: estimator)
        conversion.settings = StereoDepthSettings(strength: 1, popOut: false)
        conversion.start()
        let loadStart = CACurrentMediaTime()
        try await waitFor("the model to load", seconds: 120) {
            estimator.state == .ready || estimator.state.isFailure
        }
        guard estimator.state == .ready else {
            throw Check.failed("Model: \(estimator.state)")
        }
        print(String(format: "Model ready in %.1f s", CACurrentMediaTime() - loadStart))

        conversion.submit(image, quarterTurns: 0, now: 0)
        try await waitFor("the first depth map", seconds: 30) {
            conversion.phase == .on
        }
        // Run past the fade-in so the mesh is at full strength.
        var mesh: StereoDepthMesh?
        for step in 0...60 {
            mesh = conversion.mesh(now: Double(step) / 60)
        }
        guard let mesh else {
            throw Check.failed("No mesh after the depth map arrived")
        }
        let largest = mesh.parallax.map(abs).max() ?? 0
        guard largest > 0.01, mesh.parallax.min() != mesh.parallax.max() else {
            throw Check.failed("Depth is flat: largest parallax \(largest)")
        }
        print("Depth: \(conversion.stats.summary), largest parallax \(String(format: "%.3f", largest))")
        if arguments.count <= 3 {
            try checkDepthOrder(mesh)
        }

        try checkImageColors(device: device)
        let warp = try StereoWarpRenderer(device: device)
        let source = try texture(image, device: device)
        let eyes = try render(warp: warp, queue: queue, source: source, mesh: mesh, quarterTurns: 0)
        // A flat mesh draws the source unchanged, for comparing the edges.
        let flat = try render(
            warp: warp, queue: queue, source: source, mesh: .flat(columns: mesh.columns, rows: mesh.rows),
            quarterTurns: 0)
        try checkEyes(eyes, flat: flat)
        // A quarter turn swaps the eye size, the way a portrait phone video is shown.
        let turned = try render(warp: warp, queue: queue, source: source, mesh: mesh, quarterTurns: 1)
        guard turned.width == source.height, turned.height == source.width else {
            throw Check.failed("A quarter turn did not swap the eye size")
        }
        try writeSideBySide(eyes.left, eyes.right, width: eyes.width, height: eyes.height, to: output)
        print("Mac 2D-to-3D pipeline passed; eyes written to \(output.path). Not an iPhone result.")
    }

    // MARK: Rendering

    struct Eyes {
        let left: [UInt8]
        let right: [UInt8]
        let width: Int
        let height: Int
    }

    @MainActor static func render(
        warp: StereoWarpRenderer, queue: MTLCommandQueue, source: MTLTexture, mesh: StereoDepthMesh,
        quarterTurns: UInt32
    ) throws -> Eyes {
        guard let command = queue.makeCommandBuffer(),
            let eyes = warp.encode(command: command, source: source, mesh: mesh, quarterTurns: quarterTurns)
        else {
            throw Check.failed("Warp could not encode")
        }
        let width = eyes.left.width
        let height = eyes.left.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let leftCopy = queue.device.makeTexture(descriptor: descriptor),
            let rightCopy = queue.device.makeTexture(descriptor: descriptor),
            let blit = command.makeBlitCommandEncoder()
        else {
            throw Check.failed("No readback textures")
        }
        blit.copy(from: eyes.left, to: leftCopy)
        blit.copy(from: eyes.right, to: rightCopy)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        func bytes(_ texture: MTLTexture) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(
                &out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return out
        }
        return Eyes(left: bytes(leftCopy), right: bytes(rightCopy), width: width, height: height)
    }

    /// The eyes must differ. Their outer columns must match the flat picture,
    /// because the frame edge stays on the screen plane and no gap may open there.
    static func checkEyes(_ eyes: Eyes, flat: Eyes) throws {
        let width = eyes.width
        let height = eyes.height
        func meanDifference(_ a: [UInt8], _ b: [UInt8], pixels: [Int]) -> Double {
            let total = pixels.reduce(0) { sum, pixel in
                sum + abs(Int(a[pixel * 4 + 1]) - Int(b[pixel * 4 + 1]))
            }
            return Double(total) / Double(max(pixels.count, 1))
        }
        let everyPixel = Array(0..<(width * height))
        let between = meanDifference(eyes.left, eyes.right, pixels: everyPixel)
        guard between > 0.5 else {
            throw Check.failed("Left and right eyes are the same")
        }
        for (name, eye) in [("left", eyes.left), ("right", eyes.right)] {
            for x in [0, width - 1] {
                let column = (0..<height).map { $0 * width + x }
                let edge = meanDifference(eye, flat.left, pixels: column)
                guard edge < 4 else {
                    throw Check.failed("The \(name) eye moved at column \(x) by \(edge) levels")
                }
            }
        }
        print(String(format: "Eyes differ by %.1f levels on average; edges stay in place", between))
    }

    /// In the drawn scene the ball is nearer than the sky, so it must have less
    /// parallax. This catches a flipped reading of the model's output.
    static func checkDepthOrder(_ mesh: StereoDepthMesh) throws {
        func parallax(u: Float, v: Float) -> Float {
            mesh[Int((u * Float(mesh.columns - 1)).rounded()), Int((v * Float(mesh.rows - 1)).rounded())]
        }
        let ball = parallax(u: 0.46, v: 0.66)
        let sky = parallax(u: 0.5, v: 0.1)
        guard ball < sky else {
            throw Check.failed("The near ball is not in front of the sky: ball \(ball), sky \(sky)")
        }
        print(String(format: "Depth order: ball %.4f in front of sky %.4f", ball, sky))
    }

    // MARK: Images

    static func texture(_ image: CGImage, device: MTLDevice) throws -> MTLTexture {
        guard let texture = ImageTexture.make(image, device: device) else {
            throw Check.failed("Image upload failed")
        }
        return texture
    }

    /// A decoded JPEG has no alpha and its first byte unused; HDR photos have
    /// 10 or 16 bits per channel. Red must stay red in both.
    static func checkImageColors(device: MTLDevice) throws {
        let layouts: [(name: String, bits: Int, info: UInt32)] = [
            ("JPEG layout", 8, CGImageAlphaInfo.noneSkipFirst.rawValue),
            ("16-bit", 16, CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        ]
        for layout in layouts {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: 8, height: 8, bitsPerComponent: layout.bits, bytesPerRow: 0, space: space,
                    bitmapInfo: layout.info)
            else {
                throw Check.failed("Could not draw the \(layout.name) test picture")
            }
            context.setFillColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let image = context.makeImage(), let texture = ImageTexture.make(image, device: device) else {
                throw Check.failed("Could not upload the \(layout.name) test picture")
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            // BGRA order: red is the third byte.
            guard pixel[2] > 200, pixel[0] < 60 else {
                throw Check.failed("\(layout.name) photo colors changed: BGRA \(pixel)")
            }
        }
        print("Photo colors kept for JPEG and 16-bit layouts")
    }

    static func loadImage(_ path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Check.failed("Could not read \(path)")
        }
        return image
    }

    /// Sky, a checkered floor running into the distance and a lit ball, so the
    /// model has clear depth cues without a photo in the repository.
    static func drawnScene() -> CGImage {
        let width = 960
        let height = 540
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let space = CGColorSpaceCreateDeviceRGB()
        let sky = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.45, green: 0.65, blue: 0.95, alpha: 1), CGColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
            ]
                as CFArray, locations: [0, 1])!
        // Core Graphics puts y = 0 at the bottom.
        context.drawLinearGradient(
            sky, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.45), options: [])
        let horizon = CGFloat(height) * 0.45
        context.setFillColor(CGColor(red: 0.35, green: 0.32, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: horizon))
        for row in 0..<24 {
            let near = CGFloat(row) / 24
            let next = CGFloat(row + 1) / 24
            let y0 = horizon * (1 - near * near)
            let y1 = horizon * (1 - next * next)
            for column in -12..<12 {
                let spread = 0.15 + 0.85 * near
                let x0 = CGFloat(width) / 2 + CGFloat(column) * 80 * spread
                let x1 = x0 + 80 * spread
                let shade: CGFloat = (row + column) % 2 == 0 ? 0.25 : 0.75
                context.setFillColor(CGColor(red: shade, green: shade * 0.9, blue: shade * 0.7, alpha: 1))
                context.fill(CGRect(x: x0, y: min(y0, y1), width: x1 - x0, height: abs(y0 - y1) + 1))
            }
        }
        let ball = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 1), CGColor(red: 0.6, green: 0.15, blue: 0.1, alpha: 1)
            ]
                as CFArray, locations: [0, 1])!
        context.drawRadialGradient(
            ball, startCenter: CGPoint(x: 420, y: 200), startRadius: 4, endCenter: CGPoint(x: 460, y: 170),
            endRadius: 120, options: [])
        return context.makeImage()!
    }

    static func writeSideBySide(_ left: [UInt8], _ right: [UInt8], width: Int, height: Int, to url: URL) throws {
        var pixels = [UInt8](repeating: 0, count: width * 2 * height * 4)
        for y in 0..<height {
            let row = y * width * 4
            let out = y * width * 8
            pixels.replaceSubrange(out..<(out + width * 4), with: left[row..<(row + width * 4)])
            pixels.replaceSubrange((out + width * 4)..<(out + width * 8), with: right[row..<(row + width * 4)])
        }
        let bitmap = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width * 2, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw Check.failed("PNG export failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Check.failed("PNG export failed")
        }
    }

    @MainActor static func waitFor(_ what: String, seconds: Double, until done: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while !done() {
            guard CACurrentMediaTime() < deadline else {
                throw Check.failed("Timed out waiting for \(what)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
