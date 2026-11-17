import Foundation
import MetalKit
import SpatialMath
import simd

/// Head orientation and display settings for one frame.
struct RenderFrame {
    var orientation = SceneMath.identity
    var settings = SceneSettings()
    var stereo = false
    var live = false
    var interaction: InteractionFrame?
    var panelAnchor = SceneMath.identity
    var angularSpeed: Float = 0
}

// Metal code is shared by the iPhone view and the Mac offscreen verification harness.
final class WorldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertices: MTLBuffer
    private let vertexCount: Int
    private let inFlight = DispatchSemaphore(value: 3)
    var frame = RenderFrame()
    private(set) var submittedFrames = 0
    private(set) var skippedFrames = 0
    private(set) var error: String?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.unavailable
        }
        self.queue = queue
        let library = try device.makeLibrary(
            source: """
                #include <metal_stdlib>
                using namespace metal;
                struct LineVertex {
                    float3 position;
                    float4 color;
                };
                struct Output {
                    float4 position [[position]];
                    float4 color;
                };
                vertex Output scene_vertex(uint index [[vertex_id]],
                                           const device LineVertex *vertices [[buffer(0)]],
                                           constant float4x4 &viewProjection [[buffer(1)]]) {
                    Output out;
                    out.position = viewProjection * float4(vertices[index].position, 1.0);
                    out.color = vertices[index].color;
                    return out;
                }
                fragment float4 scene_fragment(Output input [[stage_in]]) {
                    return input.color;
                }
                """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "scene_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "scene_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let mesh = SceneGeometry.world()
        vertexCount = mesh.count
        guard
            let buffer = device.makeBuffer(
                bytes: mesh, length: mesh.count * MemoryLayout<LineVertex>.stride,
                options: .storageModeShared)
        else {
            throw RendererError.unavailable
        }
        vertices = buffer
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else {
            skippedFrames += 1
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let command = queue.makeCommandBuffer()
        else {
            inFlight.signal()
            skippedFrames += 1
            return
        }
        guard encode(command: command, pass: pass, size: view.drawableSize, frame: frame) else {
            inFlight.signal()
            skippedFrames += 1
            return
        }
        command.addCompletedHandler { [weak self, inFlight] command in
            if let failure = command.error {
                DispatchQueue.main.async {
                    self?.error = failure.localizedDescription
                }
            }
            inFlight.signal()
        }
        command.present(drawable)
        command.commit()
        submittedFrames += 1
    }

    @discardableResult
    func encode(
        command: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
        size: CGSize, frame: RenderFrame
    ) -> Bool {
        guard size.width > 0, size.height > 0,
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        let mesh = frame.interaction.map(InteractionGeometry.mesh)
        func buffer(_ values: [LineVertex]?) -> MTLBuffer? {
            guard let values, !values.isEmpty else {
                return nil
            }
            return device.makeBuffer(
                bytes: values, length: values.count * MemoryLayout<LineVertex>.stride, options: .storageModeShared)
        }
        let fillBuffer = buffer(mesh?.fill)
        let linesBuffer = buffer(mesh?.lines)
        let eyes = frame.stereo ? 2 : 1
        let width = Double(size.width) / Double(eyes)
        let projection = SceneMath.projection(
            horizontal: frame.settings.horizontalFOV, vertical: frame.settings.verticalFOV)
        for eye in 0..<eyes {
            encoder.setViewport(
                MTLViewport(
                    originX: Double(eye) * width, originY: 0,
                    width: width, height: Double(size.height), znear: 0, zfar: 1))
            // Viewports do not clip primitives to their own half; scissor explicitly prevents eye leakage.
            let x0 = Int(Double(eye) * width)
            let x1 = Int(Double(eye + 1) * width)
            encoder.setScissorRect(MTLScissorRect(x: x0, y: 0, width: x1 - x0, height: Int(size.height)))
            let offset: Float = eyes == 2 ? (eye == 0 ? -0.5 : 0.5) * frame.settings.eyeSeparationMillimeters / 1000 : 0
            var transform = projection * SceneMath.view(orientation: frame.orientation, eyeOffset: offset)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
            if let mesh, let fillBuffer, let linesBuffer {
                var panelTransform = transform * simd_float4x4(frame.panelAnchor)
                encoder.setVertexBytes(&panelTransform, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.setVertexBuffer(fillBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.fill.count)
                encoder.setVertexBuffer(linesBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: mesh.lines.count)
            }
            let overlay = SceneGeometry.overlay(live: frame.live, aspect: Float(width / Double(size.height)))
            var identity = matrix_identity_float4x4
            overlay.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.setVertexBytes(&identity, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlay.count)
        }
        encoder.endEncoding()
        return true
    }

    enum RendererError: Error { case unavailable }
}
