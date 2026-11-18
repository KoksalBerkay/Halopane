import Metal
import SpatialMath

/// Draws one 2D picture through a depth mesh into two eye pictures.
///
/// The output is already turned upright, so the caller draws the two results as
/// separate eyes with no further rotation. Each vertex keeps its place in the
/// source and only moves sideways in the eye picture, so the picture stretches
/// slightly at depth edges instead of tearing.
final class StereoWarpRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var texcoord: SIMD2<Float>
    }

    /// The longer side of an eye picture. Larger sources are scaled down to it.
    static let largestSide = 2560

    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var indices: MTLBuffer?
    private var indexCount = 0
    private var indexedGrid = (columns: 0, rows: 0)
    // Three vertex buffers, so the CPU never writes one the GPU is still reading.
    private var vertexBuffers: [MTLBuffer] = []
    private var nextBuffer = 0
    private var targets: [MTLTexture] = []

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "warpVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "warpFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Encodes both eyes into `command` and returns them, left eye first.
    /// `quarterTurns` matches the media shader's clockwise rotation.
    func encode(
        command: MTLCommandBuffer, source: MTLTexture, mesh: StereoDepthMesh, quarterTurns: UInt32
    ) -> (left: MTLTexture, right: MTLTexture)? {
        let odd = quarterTurns % 2 == 1
        let size = Self.eyeSize(
            width: odd ? source.height : source.width, height: odd ? source.width : source.height)
        guard size.width > 0, size.height > 0, prepareTargets(width: size.width, height: size.height),
            prepareIndices(columns: mesh.columns, rows: mesh.rows),
            let indices, let vertices = fillVertices(mesh: mesh, quarterTurns: quarterTurns)
        else {
            return nil
        }
        let perEye = mesh.columns * mesh.rows * MemoryLayout<Vertex>.stride
        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targets[eye]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                return nil
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertices, offset: eye * perEye, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indices,
                indexBufferOffset: 0)
            encoder.endEncoding()
        }
        return (targets[0], targets[1])
    }

    static func eyeSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > largestSide else {
            return (width, height)
        }
        let scale = Double(largestSide) / Double(longest)
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    /// Where an upright picture point samples the source, matching the media shader.
    static func sourcePoint(_ point: SIMD2<Float>, quarterTurns: UInt32) -> SIMD2<Float> {
        switch quarterTurns % 4 {
        case 1:
            return SIMD2(point.y, 1 - point.x)
        case 2:
            return SIMD2(1 - point.x, 1 - point.y)
        case 3:
            return SIMD2(1 - point.y, point.x)
        default:
            return point
        }
    }

    // MARK: Buffers

    private func prepareTargets(width: Int, height: Int) -> Bool {
        if let first = targets.first, first.width == width, first.height == height {
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let made = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        targets = made.count == 2 ? made : []
        return !targets.isEmpty
    }

    // Two triangles per cell. The grid fits in 16-bit indices.
    private func prepareIndices(columns: Int, rows: Int) -> Bool {
        if indexedGrid == (columns, rows), indices != nil {
            return true
        }
        guard columns * rows <= Int(UInt16.max) else {
            return false
        }
        var list: [UInt16] = []
        list.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let topLeft = UInt16(row * columns + column)
                let bottomLeft = UInt16((row + 1) * columns + column)
                list += [topLeft, topLeft + 1, bottomLeft, topLeft + 1, bottomLeft + 1, bottomLeft]
            }
        }
        indices = device.makeBuffer(
            bytes: list, length: list.count * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        indexCount = list.count
        indexedGrid = (columns, rows)
        vertexBuffers = []
        return indices != nil
    }

    // Left eye vertices first, then the right eye.
    private func fillVertices(mesh: StereoDepthMesh, quarterTurns: UInt32) -> MTLBuffer? {
        let count = mesh.columns * mesh.rows * 2
        let length = count * MemoryLayout<Vertex>.stride
        if vertexBuffers.count < 3 || vertexBuffers[0].length != length {
            vertexBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
        }
        guard vertexBuffers.count == 3 else {
            return nil
        }
        let buffer = vertexBuffers[nextBuffer]
        nextBuffer = (nextBuffer + 1) % 3
        let out = buffer.contents().bindMemory(to: Vertex.self, capacity: count)
        var index = 0
        for eye in 0..<2 {
            for row in 0..<mesh.rows {
                for column in 0..<mesh.columns {
                    let upright = mesh.sourcePoint(column: column, row: row)
                    out[index] = Vertex(
                        position: mesh.eyePoint(column: column, row: row, eye: eye),
                        texcoord: Self.sourcePoint(upright, quarterTurns: quarterTurns))
                    index += 1
                }
            }
        }
        return buffer
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct WarpVertex {
            float2 position;
            float2 texcoord;
        };
        struct WarpOut {
            float4 position [[position]];
            float2 texcoord;
        };
        vertex WarpOut warpVertex(uint index [[vertex_id]], const device WarpVertex *vertices [[buffer(0)]]) {
            WarpVertex v = vertices[index];
            WarpOut out;
            out.position = float4(v.position.x * 2.0 - 1.0, 1.0 - v.position.y * 2.0, 0.0, 1.0);
            out.texcoord = v.texcoord;
            return out;
        }
        fragment float4 warpFragment(WarpOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler linear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            return float4(image.sample(linear, in.texcoord).rgb, 1.0);
        }
        """
}
