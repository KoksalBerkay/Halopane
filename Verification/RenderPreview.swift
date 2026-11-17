import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import SpatialMath
import UniformTypeIdentifiers
import simd

@main
struct RenderPreview {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal unavailable")
        }
        let renderer = try WorldRenderer(device: device)
        let directory = CommandLine.arguments.dropFirst().first ?? "/tmp/viture-scene-preview"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let settings = SceneSettings()
        let poses: [(String, simd_quatf)] = [
            ("level", SceneMath.identity),
            ("right15", simd_quatf(angle: -.pi / 12, axis: SIMD3<Float>(0, 0, 1))),
            ("nod15", simd_quatf(angle: .pi / 12, axis: SIMD3<Float>(0, 1, 0))),
            ("tilt15", simd_quatf(angle: .pi / 12, axis: SIMD3<Float>(1, 0, 0)))
        ]
        var rendered = [[UInt8]]()
        for (name, raw) in poses {
            let orientation = SceneMath.cameraOrientation(
                raw: raw, settings: settings, headingReference: SceneMath.identity)
            let pixels = try render(
                renderer, width: 1920, height: 600,
                frame: RenderFrame(orientation: orientation, settings: settings, stereo: true, live: true))
            rendered.append(pixels)
            try png(pixels, width: 1920, height: 600, path: directory + "/" + name + ".png")
            let bright = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 20 || pixels[$0 + 1] > 20 || pixels[$0 + 2] > 20
            }.count
            guard bright > 1000 else {
                fatalError("Blank or sparse render for " + name)
            }
            print("\(name): \(bright) colored pixels, GPU rendering completed")
        }
        guard rendered[0] != rendered[1], rendered[0] != rendered[2], rendered[0] != rendered[3] else {
            fatalError("Head rotation failed to alter the rendered image")
        }
        // With zero eye separation the two halves must match exactly; with 63 mm they must differ.
        var zeroIPD = settings
        zeroIPD.eyeSeparationMillimeters = 0
        let monoStereo = try render(
            renderer, width: 1920, height: 600,
            frame: RenderFrame(settings: zeroIPD, stereo: true, live: true))
        func differentHalves(_ pixels: [UInt8]) -> Int {
            (0..<600).reduce(0) { count, row in
                let start = row * 1920 * 4
                return count + (0..<(960 * 4)).filter { pixels[start + $0] != pixels[start + 960 * 4 + $0] }.count
            }
        }
        guard differentHalves(monoStereo) == 0 else {
            fatalError("Zero-IPD stereo halves differ")
        }
        guard differentHalves(rendered[0]) > 1000 else {
            fatalError("63 mm stereo disparity missing")
        }
        print("Stereo checks passed: zero-IPD halves match; 63 mm halves contain disparity")
        var panel = DemoPanel()
        let pointer = PointerRay(direction: SIMD3<Float>(0, 0.14, -1.5))!
        let neutralPanel = try render(
            renderer, width: 1920, height: 600,
            frame: RenderFrame(
                settings: settings, stereo: true, live: true,
                interaction: InteractionFrame(panel: panel, ray: pointer)))
        try png(neutralPanel, width: 1920, height: 600, path: directory + "/panel-hover.png")
        guard panel.select(pointer) == 0 else {
            fatalError("Preview pointer missed row 1")
        }
        let selectedPanel = try render(
            renderer, width: 1920, height: 600,
            frame: RenderFrame(
                settings: settings, stereo: true, live: true,
                interaction: InteractionFrame(panel: panel, ray: pointer)))
        guard neutralPanel != selectedPanel else {
            fatalError("Selection did not alter the rendered count")
        }
        try png(selectedPanel, width: 1920, height: 600, path: directory + "/panel-selected.png")
        panel.beginScroll(pointer)
        panel.scroll(deltaPoints: -120)
        panel.endScroll()
        let scrolledPanel = try render(
            renderer, width: 1920, height: 600,
            frame: RenderFrame(
                settings: settings, stereo: true, live: true,
                interaction: InteractionFrame(panel: panel, ray: pointer)))
        guard scrolledPanel != selectedPanel else {
            fatalError("Scroll did not alter the rendered rows")
        }
        try png(scrolledPanel, width: 1920, height: 600, path: directory + "/panel-scrolled.png")
        for pixels in [neutralPanel, selectedPanel, scrolledPanel] {
            // Check actual pixels rather than a downscaled preview of one-pixel lines.
            let rowBorder = (250...256).reduce(0) { count, y in
                count
                    + (200..<800).filter { x in
                        let i = (y * 1920 + x) * 4
                        return max(pixels[i], pixels[i + 1], pixels[i + 2]) > 80
                    }.count
            }
            let crosshair = (295...305).reduce(0) { count, y in
                count
                    + (475...485).filter { x in
                        let i = (y * 1920 + x) * 4
                        return min(pixels[i], pixels[i + 1], pixels[i + 2]) > 230
                    }.count
            }
            guard rowBorder > 400, crosshair > 10 else {
                fatalError("Panel borders or head-locked crosshair disappeared")
            }
        }
        // Keep the camera fixed and compare actual panel pixels against the grid-only render.
        // A pitched anchor must move the panel in opposite directions, independent of the grid.
        func panelRows(_ pixels: [UInt8]) -> ClosedRange<Int> {
            let rows = (0..<600).filter { y in
                (0..<960).contains { x in
                    let i = (y * 1920 + x) * 4
                    return pixels[i] != rendered[0][i] || pixels[i + 1] != rendered[0][i + 1]
                        || pixels[i + 2] != rendered[0][i + 2]
                }
            }
            guard let first = rows.first, let last = rows.last else {
                fatalError("Panel missing")
            }
            return first...last
        }
        var midpoints = [Double]()
        for pitch: Float in [0.07, 0, -0.07] {
            let anchor = WebPanelMath.levelAnchor(lookingWith: simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0)))
            let worldPointer = anchor.act(pointer.direction)
            guard let localPointer = PointerRay(direction: anchor.inverse.act(worldPointer)),
                DemoPanel().hit(localPointer) == 0
            else {
                fatalError("Tilted panel hit mapping missed row 1")
            }
            let pixels = try render(
                renderer, width: 1920, height: 600,
                frame: RenderFrame(
                    settings: settings, stereo: true, live: true,
                    interaction: InteractionFrame(panel: DemoPanel(), ray: localPointer),
                    panelAnchor: anchor))
            let rows = panelRows(pixels)
            midpoints.append(Double(rows.lowerBound + rows.upperBound) / 2)
        }
        guard midpoints[0] < midpoints[1] - 50, midpoints[2] > midpoints[1] + 50 else {
            fatalError("Panel did not move vertically with the anchor: " + String(describing: midpoints))
        }
        print("Panel centered up and down in Metal; row 1 hit follows the new anchor")
        print(
            "Interaction checks passed: selection changes count, scrolling changes rows, panel borders and crosshair stay visible"
        )
    }

    private static func render(_ renderer: WorldRenderer, width: Int, height: Int, frame: RenderFrame) throws -> [UInt8]
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
            let command = renderer.queue.makeCommandBuffer()
        else {
            fatalError("Metal allocation failed")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard renderer.encode(command: command, pass: pass, size: CGSize(width: width, height: height), frame: frame)
        else {
            fatalError("No encoder")
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private static func png(_ pixels: [UInt8], width: Int, height: Int, path: String) throws {
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let bitmap = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("PNG export failed")
        }
    }
}
