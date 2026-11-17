import CoreMedia
import CoreVideo
import CoreImage
import MetalKit
import SpatialMath
import simd

/// Draws local videos and photos in the glasses with Metal, flat or as a 180/360 sphere.
final class NativeMediaRenderer {
    private struct Uniforms {
        var rotation: simd_float3x3
        var safe: SIMD4<Float>
        var fit: SIMD4<Float>
        var tangent: SIMD2<Float>
        var projection: UInt32
        var layout: UInt32
        var eye: UInt32
        var turns: UInt32
    }
    private struct Frame {
        let left: MTLTexture
        let right: MTLTexture?
        let retained: [CVMetalTexture]
        let decodedBuffers: [CVPixelBuffer]
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let cache: CVMetalTextureCache
    private let loader: MTKTextureLoader
    private let inFlight = DispatchSemaphore(value: 2)
    private var sourceID: UUID?
    private var lastTime = CMTime.invalid
    private var content: Frame?
    private var triedPhoto = false
    private(set) var isPresenting = false

    init(device: MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache, let queue = device.makeCommandQueue() else {
            throw WorldRenderer.RendererError.unavailable
        }
        self.cache = cache
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mediaVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "mediaFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func clear() {
        sourceID = nil
        lastTime = .invalid
        content = nil
        triedPhoto = false
        isPresenting = false
        CVMetalTextureCacheFlush(cache, 0)
    }

    @discardableResult
    private func update(session: NativeMediaSession, time: CFTimeInterval) -> Bool {
        if sourceID != session.renderID {
            clear()
            sourceID = session.renderID
        }
        if !triedPhoto, let photo = session.photo {
            triedPhoto = true
            let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
            if let left = try? loader.newTexture(cgImage: photo.0, options: options) {
                let right = photo.1.flatMap {
                    try? loader.newTexture(cgImage: $0, options: options)
                }
                content = Frame(left: left, right: right, retained: [], decodedBuffers: [])
            }
        } else if let decoded = session.sample(hostTime: time, after: lastTime) {
            lastTime = decoded.2
            if session.detectedStereo {
                let left = snapshotEye(decoded.0)
                let right = decoded.1.flatMap(snapshotEye)
                if let left, decoded.1 == nil || right != nil {
                    content = Frame(left: left, right: right, retained: [], decodedBuffers: [])
                }
                let route = [decoded.0, decoded.1].compactMap { $0 }.map {
                    MediaLuma.usesDirectCopy($0) ? "BGRA copy" : "Core Image"
                }.joined(separator: "/")
                session.diagnostics.record(
                    .init(
                        left: decoded.0, right: decoded.1, timestamp: decoded.2,
                        leftTexture: left, rightTexture: right, route: route), frame: session.decodedVideoFrames,
                    expectedStereo: true)
            } else {
                let left = texture(decoded.0)
                if let left {
                    content = Frame(left: left.0, right: nil, retained: [left.1], decodedBuffers: [decoded.0])
                }
                session.diagnostics.record(
                    .init(
                        left: decoded.0, right: nil, timestamp: decoded.2,
                        leftTexture: left?.0, rightTexture: nil, route: "Metal texture cache"),
                    frame: session.decodedVideoFrames, expectedStereo: false)
            }
        }
        return content != nil
    }

    func snapshotEye(_ buffer: CVPixelBuffer) -> MTLTexture? {
        if !MediaLuma.usesDirectCopy(buffer) {
            guard let image = MediaLuma.convertedImage(buffer) else {
                return nil
            }
            return try? loader.newTexture(
                cgImage: image,
                options: [
                    .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                    .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
                ])
        }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let address = CVPixelBufferGetBaseAddress(buffer), stride >= width * 4 else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        copy.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: address, bytesPerRow: stride)
        return copy
    }

    private func texture(_ buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var holder: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &holder)
        guard result == kCVReturnSuccess, let holder, let texture = CVMetalTextureGetTexture(holder) else {
            return nil
        }
        return (texture, holder)
    }

    func draw(
        in view: MTKView, session: NativeMediaSession, render: RenderFrame,
        safeArea: VisibleArea, hostTime: CFTimeInterval
    ) {
        let orientation = session.orientation(render)
        guard inFlight.wait(timeout: .now()) == .success else {
            return
        }
        let comparison = session.comparison
        session.diagnostics.screen(
            view.drawableSize, stereo: render.stereo,
            eyes: comparison == nil ? session.stereoEyePreview : session.comparisonEye)
        let ready = comparison != nil || update(session: session, time: hostTime)
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else {
            inFlight.signal()
            return
        }
        let data = content
        let parameters: Presentation
        if let comparison {
            parameters = Presentation(
                settings: render.settings, stereo: render.stereo,
                layout: comparison.rightTexture == nil ? .mono : .separateEyes,
                turns: comparison.turns, safeArea: safeArea, eyePreview: session.comparisonEye)
        } else {
            parameters = Presentation(
                orientation: orientation, settings: render.settings, stereo: render.stereo,
                projection: session.projection, layout: session.arrangement, swapped: session.swapEyes,
                turns: session.quarterTurns, safeArea: safeArea, eyePreview: session.stereoEyePreview)
        }
        guard
            encode(
                command: command, pass: pass, size: view.drawableSize, left: comparison?.leftTexture ?? data?.left,
                right: comparison == nil ? data?.right : comparison?.rightTexture,
                presentation: parameters)
        else {
            inFlight.signal()
            return
        }
        command.addCompletedHandler { [inFlight, data] _ in
            // Retain the CVMetalTextures until the GPU has finished sampling them.
            withExtendedLifetime(data) {
                _ = inFlight.signal()
            }
        }
        command.present(drawable)
        command.commit()
        isPresenting = ready
    }

    struct Presentation {
        var orientation = SceneMath.identity
        var settings = SceneSettings()
        var stereo = false
        var projection: MediaProjection = .flat
        var layout: MediaArrangement = .mono
        var swapped = false
        var turns: UInt32 = 0
        var safeArea = VisibleArea()
        var eyePreview: StereoEyePreview = .stereo
    }

    @discardableResult func encode(
        command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize,
        left: MTLTexture?, right: MTLTexture?, presentation: Presentation
    ) -> Bool {
        let count = presentation.stereo ? 2 : 1
        guard Int(size.width) >= count, size.height >= 1,
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else {
            return false
        }
        defer {
            encoder.endEncoding()
        }
        // Clear to black until the first sample is ready.
        guard let left else {
            return true
        }
        encoder.setRenderPipelineState(pipeline)
        let settings = presentation.settings
        let tangent = SIMD2(tan(settings.horizontalFOV * .pi / 360), tan(settings.verticalFOV * .pi / 360))
        // In stereo the drawable holds two views side by side, one per eye.
        for slot in 0..<count {
            // A right-eye preview of a clip without a right eye stays black.
            if presentation.layout == .separateEyes, presentation.eyePreview == .rightOnly, right == nil {
                continue
            }
            let eye = Self.sourceEye(forSlot: slot, presentation: presentation)
            let texture: MTLTexture
            if presentation.layout == .separateEyes && eye == 1 {
                texture = right ?? left
            } else {
                texture = left
            }
            let x0 = Int(size.width) * slot / count
            let x1 = Int(size.width) * (slot + 1) / count
            let viewport = CGRect(x: x0, y: 0, width: x1 - x0, height: Int(size.height))
            drawEye(
                encoder: encoder, texture: texture, eye: eye, viewport: viewport, tangent: tangent,
                presentation: presentation)
        }
        return true
    }

    /// Which eye of the source a screen half shows.
    /// Slot 0 is the left half of the drawable; slot 1 the right half.
    private static func sourceEye(forSlot slot: Int, presentation: Presentation) -> Int {
        let normalEye: Int
        if slot == 0 {
            normalEye = presentation.swapped && presentation.stereo ? 1 : 0
        } else {
            normalEye = presentation.swapped ? 0 : 1
        }
        let preview = presentation.layout == .separateEyes ? presentation.eyePreview : .stereo
        switch preview {
        case .stereo:
            return normalEye
        case .leftOnly:
            return 0
        case .rightOnly:
            return 1
        }
    }

    /// Width over height of one eye's picture, after rotation and packing.
    private static func eyeAspect(of texture: MTLTexture, presentation: Presentation) -> Float {
        var aspect = Float(texture.width) / Float(texture.height)
        if presentation.turns % 2 != 0 {
            aspect = 1 / aspect
        }
        if presentation.layout == .sideBySide {
            aspect *= 0.5
        }
        if presentation.layout == .overUnder {
            aspect *= 2
        }
        return aspect
    }

    /// Draws one eye into its part of the drawable, fitted inside the safe area.
    private func drawEye(
        encoder: MTLRenderCommandEncoder, texture: MTLTexture, eye: Int, viewport: CGRect,
        tangent: SIMD2<Float>, presentation: Presentation
    ) {
        let width = Int(viewport.width)
        let height = Int(viewport.height)
        let safe = presentation.safeArea.rect(in: CGSize(width: width, height: height))
        let aspect = Self.eyeAspect(of: texture, presentation: presentation)
        let fitWidth = min(safe.width, safe.height * CGFloat(aspect))
        let fitHeight = fitWidth / CGFloat(aspect)
        let fitted = CGRect(
            x: safe.midX - fitWidth / 2, y: safe.midY - fitHeight / 2, width: fitWidth, height: fitHeight)
        // The shader takes rectangles as fractions of the viewport.
        func normalized(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(
                Float(rect.minX) / Float(width), Float(rect.minY) / Float(height),
                Float(rect.width) / Float(width), Float(rect.height) / Float(height))
        }
        var uniforms = Uniforms(
            rotation: simd_float3x3(presentation.orientation), safe: normalized(safe), fit: normalized(fitted),
            tangent: tangent, projection: presentation.projection.rawValue, layout: presentation.layout.rawValue,
            eye: UInt32(eye), turns: presentation.turns)
        encoder.setViewport(
            MTLViewport(
                originX: Double(viewport.minX), originY: 0, width: Double(width), height: Double(height),
                znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: Int(viewport.minX), y: 0, width: width, height: height))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct V {
            float4 position [[position]];
            float2 uv;
        };
        struct Parameters {
            float3x3 rotation;
            float4 safe;
            float4 fit;
            float2 tangent;
            uint projection, layout, eye, turns;
        };
        vertex V mediaVertex(uint index [[vertex_id]]) {
            float2 uv = float2(index == 1 ? 2.0 : 0.0, index == 2 ? 2.0 : 0.0);
            return V{float4(uv.x * 2.0 - 1.0,1.0 - uv.y * 2.0,0.0,1.0),uv};
        }
        fragment float4 mediaFragment(V in [[stage_in]],constant Parameters &p [[buffer(0)]],
                                      texture2d<float> image [[texture(0)]]) {
            if (any(in.uv < p.safe.xy) || any(in.uv > p.safe.xy + p.safe.zw)) {
                return float4(0,0,0,1);
            }
            float2 ndc = (in.uv * 2.0 - 1.0) * float2(1,-1);
            float3 ray = p.rotation * float3(ndc * p.tangent,-1);
            float2 uv;
            bool wrap = p.projection == 2;
            if (p.projection == 0) {
                if (ray.z >= -0.001) {
                    return float4(0,0,0,1);
                }
                float2 screen = float2(0.5) + 0.5 * ray.xy / (-ray.z * p.tangent) * float2(1,-1);
                uv = (screen - p.fit.xy) / p.fit.zw;
                if (any(uv < 0.0) || any(uv > 1.0)) {
                    return float4(0,0,0,1);
                }
            } else {
                if (p.projection == 1 && ray.z > 0.0) {
                    return float4(0,0,0,1);
                }
                ray = normalize(ray);
                const float pi = 3.14159265358979323846;
                uv = float2(0.5 + atan2(ray.x,-ray.z) / (wrap ? 2.0*pi : pi),
                            0.5 - asin(clamp(ray.y,-1.0,1.0)) / pi);
            }
            // Pack within one eye. Clamp to half-texel centers so linear filtering
            // never pulls a pixel from the other eye.
            float2 inset = 0;
            bool nativeU = p.turns % 2 == 0;
            float pixelsX = nativeU ? image.get_width() : image.get_height();
            float pixelsY = nativeU ? image.get_height() : image.get_width();
            if (p.layout == 1 || p.layout == 2) {
                uv.x = (uv.x + float(p.eye))*0.5;
                inset.x = 0.5/pixelsX;
                uv.x = clamp(uv.x,float(p.eye)*0.5 + inset.x,float(p.eye+1)*0.5 - inset.x);
                wrap = false;
            } else if (p.layout == 3 || p.layout == 4) {
                uv.y = (uv.y + float(p.eye))*0.5;
                inset.y = 0.5/pixelsY;
                uv.y = clamp(uv.y,float(p.eye)*0.5 + inset.y,float(p.eye+1)*0.5 - inset.y);
            }
            if (p.turns == 1) {
                uv = float2(uv.y,1.0-uv.x);
            } else if (p.turns == 2) {
                uv = 1.0-uv;
            } else if (p.turns == 3) {
                uv = float2(1.0-uv.y,uv.x);
            }
            constexpr sampler normalSampler(mag_filter::linear,min_filter::linear,address::clamp_to_edge);
            constexpr sampler wrapHorizontal(
                mag_filter::linear,min_filter::linear,s_address::repeat,t_address::clamp_to_edge);
            constexpr sampler wrapVertical(
                mag_filter::linear,min_filter::linear,s_address::clamp_to_edge,t_address::repeat);
            float4 color;
            if (!wrap) {
                color = image.sample(normalSampler,uv);
            } else if (nativeU) {
                color = image.sample(wrapHorizontal,uv);
            } else {
                color = image.sample(wrapVertical,uv);
            }
            return float4(color.rgb,1.0);
        }
        """
}
