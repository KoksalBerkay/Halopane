import simd

/// Where one screen sits relative to the workspace.
public struct PanelOffset {
    public var rotation: simd_quatf
    public init(rotation: simd_quatf = SceneMath.identity) {
        self.rotation = rotation
    }
    public static var side: Self {
        slot(1)
    }
    public static func slot(_ index: Int) -> Self {
        switch index {
        case 1:
            return Self(rotation: simd_quatf(angle: -36 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        case 2:
            return Self(rotation: simd_quatf(angle: 36 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        case 3:
            return Self(rotation: simd_quatf(angle: 26 * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
        default:
            return Self()
        }
    }

    public func camera(_ workspaceCamera: simd_quatf) -> simd_quatf {
        (rotation.inverse * workspaceCamera).normalized
    }
    public func anchor(in workspace: simd_quatf) -> simd_quatf {
        (workspace * rotation).normalized
    }
    public func point(for worldRay: PointerRay, workspace: simd_quatf, topInset: Float = 0) -> SIMD2<Float>? {
        PointerRay(direction: anchor(in: workspace).inverse.act(worldRay.direction)).flatMap {
            WebPanelMath.point(for: $0, topInset: topInset)
        }
    }
}

/// Which screen the pointer is on, and where on it.
public struct PanelPointerHit: Equatable {
    public let panel: Int
    public let point: SIMD2<Float>

    public struct Candidate {
        public let number: Int
        public let offset: PanelOffset

        public init(number: Int, offset: PanelOffset) {
            self.number = number
            self.offset = offset
        }
    }

    /// Draw order puts the selected panel on top when panels overlap.
    public static func resolve(
        ray: PointerRay, workspace: simd_quatf, selected: Int,
        panels: [Candidate], topInset: Float
    ) -> Self? {
        let ordered = panels.filter { $0.number == selected } + panels.filter { $0.number != selected }
        for candidate in ordered {
            if let point = candidate.offset.point(for: ray, workspace: workspace, topInset: topInset) {
                return Self(panel: candidate.number, point: point)
            }
        }
        return nil
    }
}
