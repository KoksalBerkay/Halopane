import CoreGraphics
import Foundation
import MetalKit
import SpatialMath
import simd

/// Experimental backend: draws page snapshots with Metal.
final class WebSnapshotRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertices: MTLBuffer
    private var texture: MTLTexture?
    private let loader: MTKTextureLoader
    private let pending = DispatchSemaphore(value: 3)
    var frame = RenderFrame()
    private(set) var submittedFrames = 0
    private(set) var skippedFrames = 0
    private(set) var error: String?
    struct Vertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    init(device: MTLDevice) throws {
        self.device = device
        loader = MTKTextureLoader(device: device)
        guard let queue = device.makeCommandQueue() else {
            throw Failure.noDevice
        }
        self.queue = queue
        let library = try device.makeLibrary(
            source: """
                #include <metal_stdlib>
                using namespace metal;
                struct V {
                    float3 position;
                    float2 uv;
                };
                struct O {
                    float4 position [[position]];
                    float2 uv;
                };
                vertex O vmain(
                    uint i [[vertex_id]], const device V* v [[buffer(0)]], constant float4x4& m [[buffer(1)]]
                ) {
                    O o;
                    o.position=m*float4(v[i].position,1);
                    o.uv=v[i].uv;
                    return o;
                }
                fragment float4 fmain(O o [[stage_in]],texture2d<float> image [[texture(0)]]) {
                    constexpr sampler s(filter::linear,address::clamp_to_edge);
                    return image.sample(s,o.uv);
                }
                """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vmain")
        descriptor.fragmentFunction = library.makeFunction(name: "fmain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let w = WebPanelMath.width / 2, h = WebPanelMath.height / 2, z = -WebPanelMath.depth
        let quad = [
            Vertex(position: SIMD3(-w, h, z), uv: SIMD2(0, 0)), Vertex(position: SIMD3(w, h, z), uv: SIMD2(1, 0)),
            Vertex(position: SIMD3(-w, -h, z), uv: SIMD2(0, 1)), Vertex(position: SIMD3(w, h, z), uv: SIMD2(1, 0)),
            Vertex(position: SIMD3(w, -h, z), uv: SIMD2(1, 1)), Vertex(position: SIMD3(-w, -h, z), uv: SIMD2(0, 1))
        ]
        guard
            let buffer = device.makeBuffer(
                bytes: quad, length: quad.count * MemoryLayout<Vertex>.stride, options: .storageModeShared)
        else {
            throw Failure.noDevice
        }
        vertices = buffer
        super.init()
    }
    func upload(_ image: CGImage) throws -> Double {
        let start = CACurrentMediaTime()
        texture = try loader.newTexture(
            cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
        return (CACurrentMediaTime() - start) * 1000
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard texture != nil, pending.wait(timeout: .now()) == .success else {
            skippedFrames += 1
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else {
            skippedFrames += 1
            pending.signal()
            return
        }
        guard encode(command: command, pass: pass, size: view.drawableSize, frame: frame) else {
            skippedFrames += 1
            pending.signal()
            return
        }
        command.addCompletedHandler { [weak self, pending] command in
            if let failure = command.error {
                DispatchQueue.main.async {
                    self?.error = failure.localizedDescription
                }
            }
            pending.signal()
        }
        command.present(drawable)
        command.commit()
        submittedFrames += 1
    }
    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, frame: RenderFrame) -> Bool {
        guard size.width > 0, size.height > 0, let texture,
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        let count = frame.stereo ? 2 : 1
        let width = Double(size.width) / Double(count), height = Double(size.height)
        for eye in 0..<count {
            encoder.setViewport(
                MTLViewport(originX: Double(eye) * width, originY: 0, width: width, height: height, znear: 0, zfar: 1))
            encoder.setScissorRect(
                MTLScissorRect(x: Int(Double(eye) * width), y: 0, width: Int(width), height: Int(height)))
            let offset: Float =
                count == 2 ? (eye == 0 ? -0.5 : 0.5) * frame.settings.eyeSeparationMillimeters / 1000 : 0
            var matrix =
                SceneMath.projection(horizontal: frame.settings.horizontalFOV, vertical: frame.settings.verticalFOV)
                * SceneMath.view(orientation: frame.orientation, eyeOffset: offset)
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        return true
    }
    enum Failure: Error { case noDevice }
}
